// crew-runner.ts — agentic tool loop over cliproxy HTTP (plan §6 Option A).
//
// This REPLACES pi foreman's subprocess crew transport (my-pi-harness/extensions/foreman
// /index.ts:236-340 `runAgent`, which spawns `pi --mode json`). Instead of a subprocess we POST
// plain OpenAI chat-completions to cliproxy and run the tool loop in-process.
//
// CAP-FREE BILLING (verified live 2026-06-10): a trivial call to cliproxy reports ~2065 prompt
// tokens for a one-line user message — cliproxy itself injects the Claude Code system-prompt marker
// before forwarding upstream, so the call draws the interactive Max subscription quota, NOT the
// capped Agent-SDK bucket and NOT billed API credits. We therefore send a PLAIN OpenAI completion;
// no marker is needed on our side. (This is why crew is cliproxy-HTTP, not the Agent SDK — see
// docs/mcp-maestro-plan.md §4 "THE BILLING CRUX".)

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execSync } from "node:child_process";
import type { LoopToolEvent } from "./core/loopbreaker.ts";

const CLIPROXY_URL = process.env.CLIPROXY_BASE_URL || "http://localhost:8317/v1";

export type Role = "developer" | "ui-developer" | "tester" | "reviewer" | "planner" | "scout";

// cliproxy model ids (verified present in GET /v1/models on 2026-06-10). Decorrelated by design:
// implementers ≠ judges (judges on Opus, developer on GPT). Mirrors pi foreman routing.
export const ROLE_MODEL: Record<Role, string> = {
  planner: "claude-opus-4-8",
  developer: "gpt-5.5",
  "ui-developer": "gemini-3.5-flash-low",
  tester: "claude-opus-4-8",
  reviewer: "claude-opus-4-8",
  scout: "gemini-3.5-flash-low",
};

// Optional reasoning effort per role (passed as OpenAI `reasoning_effort` body param; cliproxy maps
// it to the upstream thinking level — verified with gpt-5.5 + reasoning_effort:"low").
export const ROLE_EFFORT: Partial<Record<Role, string>> = {
  planner: "high",
  tester: "high",
  reviewer: "high",
  developer: "high",
};

// Only implementers may mutate the tree. Read-only roles get no write/edit and a read-only bash.
const WRITER_ROLES: Role[] = ["developer", "ui-developer"];

export interface RunCrewOptions {
  cwd: string; // target repo root — all tool ops resolve here
  crewDir?: string; // dir holding <role>.md prompts (default: my-claude-harness/crew)
  stepCap?: number; // max tool-loop iterations (default per role)
  maxTokens?: number;
  apiKey?: string;
  onEvent?: (ev: CrewEvent) => void; // observability hook (used by the ledger later)
  // Loop-breaker telemetry: the within-round drift detector is fed the same tool_call/tool_result
  // shape foreman records to transcripts (foreman index.ts:301-331 runAgent onToolEvent). A hard
  // trip aborts via `signal`; this runner only emits + obeys the signal — the detector lives outside.
  onToolEvent?: (event: LoopToolEvent) => void;
  signal?: AbortSignal;
}

export interface CrewEvent {
  kind: "model_call" | "tool_call" | "tool_result" | "final" | "error";
  role: Role;
  step: number;
  name?: string;
  preview?: string;
}

export interface RunCrewResult {
  finalText: string;
  steps: number;
  toolCalls: number;
  model: string;
  stoppedReason: "stop" | "step_cap" | "error" | "aborted";
}

// ── cliproxy auth ────────────────────────────────────────────────────────────
// Mirrors my-pi-harness/config/models.json: read the first api-keys entry from the proxy config.
export function cliproxyKey(explicit?: string): string {
  if (explicit) return explicit;
  if (process.env.CLIPROXY_API_KEY) return process.env.CLIPROXY_API_KEY;
  const cfg = path.join(os.homedir(), "cliproxyapi", "config.yaml");
  const txt = fs.readFileSync(cfg, "utf8");
  const m = txt.match(/api-keys:\s*\n\s*-\s*"?([A-Za-z0-9_\-]+)"?/);
  if (!m) throw new Error(`cliproxy api-key not found in ${cfg}`);
  return m[1];
}

// ── crew prompt loading ──────────────────────────────────────────────────────
function defaultCrewDir(): string {
  // self-contained: foreman crew prompts copied into maestro-mcp/crew/ (sibling of this file)
  return path.resolve(new URL(".", import.meta.url).pathname, "crew");
}

function loadCrewPrompt(role: Role, crewDir: string): string {
  const file = path.join(crewDir, `${role}.md`);
  const raw = fs.readFileSync(file, "utf8");
  // strip leading YAML frontmatter (--- ... ---)
  const fm = raw.match(/^---\n[\s\S]*?\n---\n?/);
  return (fm ? raw.slice(fm[0].length) : raw).trim();
}

// ── tool schemas (OpenAI function-calling) ───────────────────────────────────
type ToolDef = { type: "function"; function: { name: string; description: string; parameters: unknown } };

const READ_TOOLS: ToolDef[] = [
  fn("read_file", "Read a UTF-8 text file. Returns its content.", {
    path: { type: "string", description: "path relative to repo root (or absolute)" },
  }, ["path"]),
  fn("list_dir", "List entries of a directory.", { path: { type: "string" } }, ["path"]),
  fn("grep", "Search files for a regex (ripgrep if available, else grep). Returns matching lines.", {
    pattern: { type: "string" }, path: { type: "string", description: "optional dir/file to search" },
  }, ["pattern"]),
  fn("bash", "Run a read-only shell command (no file mutation). Returns stdout+stderr.", {
    command: { type: "string" },
  }, ["command"]),
];

const WRITE_TOOLS: ToolDef[] = [
  fn("write_file", "Create or overwrite a UTF-8 text file with the given content.", {
    path: { type: "string" }, content: { type: "string" },
  }, ["path", "content"]),
  fn("edit_file", "Replace the first exact occurrence of old_string with new_string in a file.", {
    path: { type: "string" }, old_string: { type: "string" }, new_string: { type: "string" },
  }, ["path", "old_string", "new_string"]),
];

function fn(name: string, description: string, props: Record<string, unknown>, required: string[]): ToolDef {
  return { type: "function", function: { name, description, parameters: { type: "object", properties: props, required } } };
}

function toolsForRole(role: Role): ToolDef[] {
  return WRITER_ROLES.includes(role) ? [...READ_TOOLS, ...WRITE_TOOLS] : READ_TOOLS;
}

// ── tool execution (in-process, scoped to cwd) ───────────────────────────────
function resolveIn(cwd: string, p: string): string {
  const abs = path.isAbsolute(p) ? p : path.join(cwd, p);
  return abs;
}

function executeTool(name: string, args: any, cwd: string, role: Role): string {
  try {
    switch (name) {
      case "read_file":
        return fs.readFileSync(resolveIn(cwd, args.path), "utf8").slice(0, 60000);
      case "list_dir":
        return fs.readdirSync(resolveIn(cwd, args.path)).join("\n");
      case "grep": {
        const target = args.path ? resolveIn(cwd, args.path) : cwd;
        const bin = hasRipgrep() ? `rg -n --no-heading` : `grep -rn`;
        return sh(`${bin} -- ${shq(args.pattern)} ${shq(target)}`, cwd) || "(no matches)";
      }
      case "bash": {
        if (!WRITER_ROLES.includes(role) && looksMutating(args.command)) {
          return "ERROR: read-only role may not run a mutating shell command.";
        }
        return sh(args.command, cwd);
      }
      case "write_file": {
        const abs = resolveIn(cwd, args.path);
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        fs.writeFileSync(abs, args.content);
        return `wrote ${args.content.length} bytes to ${args.path}`;
      }
      case "edit_file": {
        const abs = resolveIn(cwd, args.path);
        const cur = fs.readFileSync(abs, "utf8");
        if (!cur.includes(args.old_string)) return `ERROR: old_string not found in ${args.path}`;
        fs.writeFileSync(abs, cur.replace(args.old_string, args.new_string));
        return `edited ${args.path}`;
      }
      default:
        return `ERROR: unknown tool ${name}`;
    }
  } catch (e: any) {
    return `ERROR: ${e?.message ?? String(e)}`;
  }
}

function sh(command: string, cwd: string): string {
  try {
    return execSync(command, { cwd, encoding: "utf8", timeout: 120000, stdio: ["ignore", "pipe", "pipe"] }).slice(0, 40000);
  } catch (e: any) {
    const out = `${e?.stdout ?? ""}${e?.stderr ?? ""}`.slice(0, 40000);
    return `exit ${e?.status ?? "?"}\n${out}`;
  }
}
function shq(s: string): string { return `'${String(s).replace(/'/g, "'\\''")}'`; }
function hasRipgrep(): boolean { try { execSync("command -v rg", { stdio: "ignore" }); return true; } catch { return false; } }
function looksMutating(cmd: string): boolean {
  return /(^|\s|;|\|\||&&|\|)\s*(rm|mv|cp|sed\s+-i|tee|dd|truncate|>|>>|git\s+(add|commit|apply|reset|checkout|stash|clean))\b/.test(cmd);
}

// Derive the loop-breaker `ok` flag from a tool result string. executeTool() encodes failure as an
// "ERROR: …" prefix (thrown/guard/unknown-tool) or sh()'s "exit <n>\n…" (execSync only throws on a
// non-zero exit, so any "exit <n>" prefix is a failure). Everything else is a success result.
function toolResultOk(result: string): boolean {
  return !/^ERROR:/.test(result) && !/^exit \d+/.test(result);
}

// ── the agentic loop ─────────────────────────────────────────────────────────
export async function runCrew(role: Role, goalHandoff: string, opts: RunCrewOptions): Promise<RunCrewResult> {
  const key = cliproxyKey(opts.apiKey);
  const crewDir = opts.crewDir || defaultCrewDir();
  const model = ROLE_MODEL[role];
  const tools = toolsForRole(role);
  const stepCap = opts.stepCap ?? (WRITER_ROLES.includes(role) ? 40 : 20);
  const emit = (ev: CrewEvent) => opts.onEvent?.(ev);

  const messages: any[] = [
    { role: "system", content: loadCrewPrompt(role, crewDir) },
    { role: "user", content: goalHandoff },
  ];

  // Loop-breaker telemetry must NEVER crash the runner (foreman NEVER invariant, index.ts:312) —
  // the detector is best-effort observability around the real tool loop.
  const emitLoop = (event: LoopToolEvent) => { try { opts.onToolEvent?.(event); } catch { /* best-effort */ } };
  const aborted = (step: number, toolCalls: number): RunCrewResult =>
    ({ finalText: "(loop-breaker aborted the run)", steps: step, toolCalls, model, stoppedReason: "aborted" });

  let toolCalls = 0;
  for (let step = 0; step < stepCap; step++) {
    if (opts.signal?.aborted) return aborted(step, toolCalls);
    emit({ kind: "model_call", role, step });
    const body: any = { model, messages, tools, max_tokens: opts.maxTokens ?? 8000 };
    if (ROLE_EFFORT[role]) body.reasoning_effort = ROLE_EFFORT[role];

    let resp: Response;
    try {
      resp = await fetch(`${CLIPROXY_URL}/chat/completions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: opts.signal,
      });
    } catch (e: any) {
      if (opts.signal?.aborted) return aborted(step, toolCalls); // hard-trip aborted the in-flight call
      throw e;
    }
    if (!resp.ok) {
      const txt = await resp.text();
      emit({ kind: "error", role, step, preview: `${resp.status} ${txt.slice(0, 200)}` });
      return { finalText: `ERROR ${resp.status}: ${txt.slice(0, 500)}`, steps: step, toolCalls, model, stoppedReason: "error" };
    }
    const data: any = await resp.json();
    const choice = data.choices?.[0];
    const msg = choice?.message ?? {};
    messages.push(msg);

    if (choice?.finish_reason === "tool_calls" && Array.isArray(msg.tool_calls)) {
      for (const tc of msg.tool_calls) {
        const name = tc.function?.name;
        let args: any = {};
        try { args = JSON.parse(tc.function?.arguments || "{}"); } catch { /* leave {} */ }
        emit({ kind: "tool_call", role, step, name, preview: JSON.stringify(args).slice(0, 160) });
        emitLoop({ kind: "tool_call", name, args }); // detector hashes the REAL args, not the 160-char preview
        const result = executeTool(name, args, opts.cwd, role);
        toolCalls++;
        emit({ kind: "tool_result", role, step, name, preview: result.slice(0, 160) });
        emitLoop({ kind: "tool_result", name, ok: toolResultOk(result), preview: result }); // full preview → error-signature normalization
        messages.push({ role: "tool", tool_call_id: tc.id, content: result });
      }
      // A hard trip during this batch aborts the monitor's signal — stop before the next model call.
      if (opts.signal?.aborted) return aborted(step + 1, toolCalls);
      continue;
    }

    const finalText = typeof msg.content === "string" ? msg.content : "";
    emit({ kind: "final", role, step, preview: finalText.slice(0, 160) });
    return { finalText, steps: step + 1, toolCalls, model, stoppedReason: "stop" };
  }

  return { finalText: "(step cap reached without a final message)", steps: stepCap, toolCalls, model, stoppedReason: "step_cap" };
}
