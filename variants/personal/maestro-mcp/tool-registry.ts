// tool-registry.ts — the "pi feeling" extensibility layer (plan §10 "harness-of-harnesses").
// Just as pi.registerTool lets the founder wire arbitrary harness tools into the session, this lets
// the MCP server expose many harness tools, each a first-class coded controller. server.ts wires the
// registry to MCP; new harnesses register here without touching the server.

import * as fs from "node:fs";
import * as path from "node:path";
import { startTask, resume, type GatePayload } from "./controller.ts";

export interface HarnessTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  handler: (args: Record<string, any>) => Promise<{ text: string; isError?: boolean }>;
}

const registry: HarnessTool[] = [];
export function registerTool(t: HarnessTool): void {
  if (registry.some((r) => r.name === t.name)) throw new Error(`tool already registered: ${t.name}`);
  registry.push(t);
}
export function getTools(): HarnessTool[] {
  return registry;
}

function payloadText(p: GatePayload): string {
  return `${p.message}\n\n---MAESTRO-JSON---\n${JSON.stringify(p, null, 2)}`;
}

// ── tool 1: maestro — the gated loop ─────────────────────────────────────────
registerTool({
  name: "maestro",
  description:
    "Gated coded orchestration loop (faithful pi+foreman replica). START: maestro({task, " +
    "verifyCommand?, track?, cwd?}) → awaiting_gate1 with the plan's understanding layer. RESUME: " +
    "maestro({resume:true, slug, approve:true}) or maestro({resume:true, slug, reject:'<feedback>'}); " +
    "gate:2 for the ship gate. Crew runs on cliproxy (Max quota). Relay gates via AskUserQuestion.",
  inputSchema: {
    type: "object",
    properties: {
      task: { type: "string" }, resume: { type: "boolean" }, slug: { type: "string" },
      approve: { type: "boolean" }, reject: { type: "string" }, gate: { type: "number" },
      track: { type: "string", enum: ["backend", "frontend"] },
      verifyCommand: { type: "string" }, cwd: { type: "string" },
    },
  },
  handler: async (a) => {
    const cwd = typeof a.cwd === "string" && a.cwd ? a.cwd : process.cwd();
    if (a.resume) {
      if (!a.slug) return { text: "resume requires a slug", isError: true };
      return { text: payloadText(await resume(a.slug, { approve: a.approve, reject: a.reject, gate: a.gate }, { cwd })) };
    }
    if (!a.task) return { text: "start requires a task", isError: true };
    return { text: payloadText(await startTask(a.task, { cwd, track: a.track, verifyCommand: a.verifyCommand })) };
  },
});

// ── tool 2: maestro-status — read-only task poll (useful for long-running tasks) ─────────────────
registerTool({
  name: "maestro-status",
  description:
    "Read the current state of a maestro task without running any crew: maestro-status({slug, cwd?}). " +
    "Returns phase, round, verdicts, DoD checklist, and blockers from the ledger. Cheap status poll.",
  inputSchema: { type: "object", properties: { slug: { type: "string" }, cwd: { type: "string" } }, required: ["slug"] },
  handler: async (a) => {
    const cwd = typeof a.cwd === "string" && a.cwd ? a.cwd : process.cwd();
    const statePath = path.join(cwd, ".claude", "maestro", a.slug, "state.json");
    if (!fs.existsSync(statePath)) return { text: `no maestro task '${a.slug}' under ${cwd}`, isError: true };
    const s = JSON.parse(fs.readFileSync(statePath, "utf8"));
    return {
      text:
        `maestro task '${a.slug}': phase=${s.state} round=${s.round} ` +
        `gate1=${s.gate1Approved} gate2=${s.gate2Approved}\n` +
        `verdicts: ${JSON.stringify(s.verdicts)}\nblockers: ${JSON.stringify(s.blockers)}\n` +
        `---STATUS-JSON---\n${JSON.stringify(s, null, 2)}`,
    };
  },
});
