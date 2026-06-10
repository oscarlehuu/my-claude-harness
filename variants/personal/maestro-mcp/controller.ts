// controller.ts — the coded loop, PHASED for the gate/resume protocol (M2 machine loop + M3 gates).
// Each MCP call does one phase, persists state.json, and returns a gate payload; the CTO relays the
// gate to the founder (AskUserQuestion) and calls back to resume. This is the rewritten orchestrator;
// it drives the reused byte-identical core/ decision modules and the cliproxy crew-runner. M4 wires
// strict DoD (done.ts) + commit (ship.ts) into the Gate-2 approve branch.

import { execSync } from "node:child_process";
import { runCrew, type Role } from "./crew-runner.ts";
import {
  validatePlannerPlan, fallbackPlannerPlan, formatIntentContract,
  type PlannerPlan, type PlannerContext,
} from "./core/planner.ts";
import { loadGates, gatesForStage, runCommandGates } from "./core/gates.ts";
import { parseReviewVerdict, decideReviewOutcome } from "./core/reviewer.ts";
import { evaluateDoneness, renderDoneChecklist, type DonenessInput, type DoneTesterState } from "./core/done.ts";
import { buildCommitMessage, resolveStagePaths, decideShipCommit } from "./core/ship.ts";
import { createLoopRunMonitor, countHardTripRounds, loopVerdictSummary, type LoopRunMonitor } from "./loop-monitor.ts";
import { Ledger, slugify } from "./state-store.ts";

function mapTesterState(v: string): DoneTesterState | undefined {
  return ({ PASS: "success", FAIL: "fail", PARTIAL: "partial", BLOCKED: "blocked" } as const)[v as "PASS"];
}

// Build the strict-DoD input from persisted state (reviewer gate is always declared in maestro).
function donenessInput(ledger: Ledger, gate2Approved: boolean): DonenessInput {
  const last = ledger.state.verdicts[ledger.state.verdicts.length - 1];
  const cg = (ledger.state as any).lastCommandGates as "pass" | "fail" | "n/a" | undefined;
  return {
    gate1Approved: ledger.state.gate1Approved,
    gate2Approved,
    latestTesterState: last ? mapTesterState(last.tester ?? "") : undefined,
    perRoundCommandGatesPassed: cg === undefined || cg === "n/a" ? undefined : cg === "pass",
    reviewerGateDeclared: true,
    reviewerDecision: (last?.reviewer as any) ?? "unknown",
  };
}

export interface StartOptions {
  cwd: string;
  track?: "backend" | "frontend";
  verifyCommand?: string;
  slug?: string;
  maxRounds?: number;
  onProgress?: (line: string) => void;
}

export interface GatePayload {
  slug: string;
  phase: "awaiting_gate1" | "awaiting_gate2" | "done" | "halted";
  planSource?: "planner" | "fallback";
  planSummary?: string;
  understanding?: string;
  assumptions?: Array<{ text: string; confidence?: string }>;
  nonGoals?: string[];
  filesChanged?: string[];
  commandGates?: "pass" | "fail" | "n/a";
  testerVerdict?: string;
  reviewVerdict?: string;
  reviewReopens?: boolean;
  message: string; // founder-facing relay text (CTO renders + AskUserQuestion)
}

// ── faithful PLAN-JSON / DEV-JSON extractor (foreman index.ts:486-507 NEVER boundary) ────────────
export function extractJsonBlock(text: string, marker: string): any | null {
  const start = `---${marker}---`;
  let from = 0;
  while (true) {
    const s = text.indexOf(start, from);
    if (s < 0) return null;
    const afterStart = s + start.length;
    const endIdx = text.indexOf(`---END-${marker}---`, afterStart);
    const slice = (endIdx >= 0 ? text.slice(afterStart, endIdx) : text.slice(afterStart)).trim();
    const cleaned = slice.replace(/^```[a-z]*\n?/i, "").replace(/```$/, "").trim();
    try { return JSON.parse(cleaned); } catch { /* keep scanning */ }
    from = afterStart;
  }
}

export function parseTesterVerdict(text: string): "PASS" | "FAIL" | "PARTIAL" | "BLOCKED" | "UNKNOWN" {
  const m = text.match(/VERDICT:\s*(PASS|FAIL|PARTIAL|BLOCKED)/i);
  return (m ? m[1].toUpperCase() : "UNKNOWN") as any;
}

const PLAN_JSON_KEYS =
  "\n\nCRITICAL OUTPUT: the ---PLAN-JSON--- block MUST use EXACTLY these top-level keys and NO " +
  "others: summary, understanding, assumptions, nonGoals, alternatives, blastRadius, steps, " +
  "filesLikely, risks, proposedGates, requirements. Do not invent keys (no objective/track/files/" +
  "verification). Include understanding-layer keys even when empty.";

function changeDiff(cwd: string): string {
  try {
    execSync("git add -A", { cwd, stdio: "ignore" });
    // Exclude maestro's own ledger/state from the judged diff: it sorts first alphabetically and
    // is large enough to consume the size cap before any production change appears, leaving the
    // tester/reviewer to judge pure harness noise.
    return execSync(
      "git diff --cached -- . ':(exclude).claude/maestro*' ':(exclude)*.DS_Store'",
      { cwd, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
    ).slice(0, 150000);
  } catch {
    return "(no git repo — diff unavailable)";
  }
}

function crewFor(ledger: Ledger, cwd: string, progress: (l: string) => void) {
  return (role: Role, prompt: string, monitor?: LoopRunMonitor) =>
    runCrew(role, prompt, {
      cwd,
      onEvent: (ev) => {
        ledger.log({ type: "crew", role, kind: ev.kind, name: ev.name, step: ev.step });
        if (ev.kind === "tool_call") progress(`  ${role}: ${ev.name} ${ev.preview ?? ""}`);
      },
      // Within-round loop-breaker: feed the monitor the crew's tool telemetry; its signal aborts on a hard trip.
      onToolEvent: monitor?.onToolEvent,
      signal: monitor?.signal,
    });
}

// ── PHASE 1: start → plan → pause at Gate 1 ──────────────────────────────────
export async function startTask(task: string, opts: StartOptions): Promise<GatePayload> {
  const cwd = opts.cwd;
  const track = opts.track ?? "backend";
  const slug = opts.slug ?? slugify(task);
  const progress = (l: string) => opts.onProgress?.(l);
  const ledger = new Ledger(cwd, slug, task, track);
  ledger.log({ type: "task_start", task, track });
  if (opts.verifyCommand) ledger.state.blockers = [];
  (ledger.state as any).verifyCommand = opts.verifyCommand ?? null;

  const crew = crewFor(ledger, cwd, progress);
  progress("• planner");
  const planRes = await crew(
    "planner",
    `Task: ${task}\nRepository root: ${cwd}\nTrack: ${track}\n\nDo read-only recon, then produce the Gate 1 plan ending with the ---PLAN-JSON--- block.${PLAN_JSON_KEYS}`,
  );
  const planJson = extractJsonBlock(planRes.finalText, "PLAN-JSON");
  const ctx: PlannerContext = { task, cwd, track, maxRounds: opts.maxRounds ?? 3, verifyCommand: opts.verifyCommand };
  const validated = validatePlannerPlan(planJson);
  const plan: PlannerPlan = validated ?? fallbackPlannerPlan(ctx);
  const planSource: "planner" | "fallback" = validated ? "planner" : "fallback";

  ledger.writePlan(plan, planRes.finalText);
  ledger.state.planSource = planSource;
  ledger.state.state = "awaiting_gate1";
  ledger.writeState();
  ledger.log({ type: "gate1_awaiting", source: planSource, summary: plan.summary });

  const understanding = plan.understanding || "";
  const assumptions = (plan.assumptions || []).map((a) => ({ text: a.text, confidence: a.confidence }));
  return {
    slug, phase: "awaiting_gate1", planSource, planSummary: plan.summary,
    understanding, assumptions, nonGoals: plan.nonGoals || [],
    message:
      `GATE 1 — plan ready (source: ${planSource}).\n\nUnderstanding: ${understanding}\n` +
      `Assumptions: ${assumptions.map((a) => `${a.text}${a.confidence ? ` (${a.confidence})` : ""}`).join("; ") || "none"}\n` +
      `Non-goals: ${(plan.nonGoals || []).join("; ") || "none"}\n\n` +
      `Approve → maestro({resume:true, slug:"${slug}", approve:true}). Revise → maestro({resume:true, slug:"${slug}", reject:"<feedback>"}).`,
  };
}

// ── the implement cycle (dev → command gate → tester → reviewer), one round ──
async function implementCycle(ledger: Ledger, cwd: string, progress: (l: string) => void): Promise<GatePayload> {
  const crew = crewFor(ledger, cwd, progress);
  const slug = ledger.state.slug;
  const track = ledger.state.track;
  const task = ledger.state.task;
  const verifyCommand: string | undefined = (ledger.state as any).verifyCommand ?? undefined;
  const plan = ledger.readPlan() as PlannerPlan;
  const intent = formatIntentContract(plan);
  const round = (ledger.state.round || 0) + 1;
  ledger.state.round = round;
  ledger.state.state = "implementing";
  ledger.writeState();

  const devRole: Role = track === "frontend" ? "ui-developer" : "developer";
  const baseDevContext =
    `Task: ${task}\n\n${intent}\n\nImplement the smallest change that satisfies the task on disk. ` +
    `End your final message with a ---DEV-JSON--- block: {"filesChanged":["path - what changed"]}.`;

  // Developer run carries a within-round loop monitor (foreman INTERNALS §10). A HARD trip aborts the
  // run mid-flight — its output is unusable — so we retry ONCE with an explicit re-plan note prepended,
  // then escalate rather than burn rounds. The SAME signature hard-tripping across 2 distinct rounds
  // also escalates: a stuck role is never infinite-looped (foreman index.ts:579, INTERNALS §09 #145).
  const MAX_DEV_ATTEMPTS = 2;
  let devRes: Awaited<ReturnType<typeof crew>>;
  let devContext = baseDevContext;
  for (let attempt = 1; ; attempt++) {
    const devMonitor = createLoopRunMonitor({ role: devRole, round, log: (e) => ledger.log(e) });
    progress(`• ${devRole} (round ${round}${attempt > 1 ? `, attempt ${attempt}` : ""})`);
    devRes = await crew(devRole, devContext, devMonitor);
    devMonitor.dispose();
    const devTrip = devMonitor.hardTrip();
    if (!devTrip) break;
    const priorRounds = countHardTripRounds(ledger.dir, devTrip.signature);
    if (attempt >= MAX_DEV_ATTEMPTS || priorRounds >= 2) {
      const summary = loopVerdictSummary(devTrip);
      ledger.state.state = "halted";
      ledger.writeState();
      ledger.log({ type: "loop_escalated", round, role: devRole, signature: devTrip.signature, priorRounds });
      return {
        slug, phase: "halted",
        message:
          `LOOP BREAKER — the ${devRole} hard-looped on: ${summary}. Stopped to avoid an infinite loop ` +
          `(no progress across attempts). NEEDS DECISION: change the approach, split the task, or adjust ` +
          `constraints, then start a revised task.`,
      };
    }
    devContext = `LOOP DETECTED last attempt: ${loopVerdictSummary(devTrip)}. Do NOT retry the same approach; change tactics.\n\n${baseDevContext}`;
  }
  ledger.writeHandoff(`round-${round}-dev`, devContext);
  const devJson = extractJsonBlock(devRes.finalText, "DEV-JSON") ?? {};
  let filesChanged: string[] = Array.isArray(devJson.filesChanged) ? devJson.filesChanged : [];
  if (filesChanged.length === 0) {
    // DEV-JSON can be missing/garbled even when real work landed; an empty list misleads the
    // tester ("developer reported filesChanged: []") and the release-commit staging. Recover
    // the truth from git, excluding maestro's own state.
    try {
      execSync("git add -A", { cwd, stdio: "ignore" });
      filesChanged = execSync(
        "git diff --cached --name-only -- . ':(exclude).claude/maestro*' ':(exclude)*.DS_Store'",
        { cwd, encoding: "utf8" },
      ).split("\n").filter(Boolean);
    } catch { /* no git repo — leave empty */ }
  }
  ledger.log({ type: "dev_done", round, filesChanged });

  let commandGates: "pass" | "fail" | "n/a" = "n/a";
  if (verifyCommand) {
    progress(`• command gate: ${verifyCommand}`);
    const gates = loadGates(cwd, verifyCommand);
    const res = await runCommandGates(gatesForStage(gates, "per-round"), "per-round", cwd);
    commandGates = res.passed ? "pass" : "fail";
    ledger.log({ type: "command_gates", round, passed: res.passed });
  }

  const diff = changeDiff(cwd);
  progress("• tester");
  const testerPrompt =
    `${intent}\n\nThe developer reported filesChanged: ${JSON.stringify(filesChanged)}.\n` +
    `Per-round command gate result: ${commandGates}. A non-zero command gate is FAIL regardless.\n\n` +
    `Judge whether the DIFF below genuinely satisfies the GOAL (catch cheats). End with ` +
    `VERDICT: PASS|FAIL|PARTIAL|BLOCKED.\n\nDIFF:\n${diff}`;
  const testerMonitor = createLoopRunMonitor({ role: "tester", round, log: (e) => ledger.log(e) });
  const testerRes = await crew("tester", testerPrompt, testerMonitor);
  testerMonitor.dispose();
  ledger.writeHandoff(`round-${round}-tester`, testerPrompt);
  let testerVerdict = parseTesterVerdict(testerRes.finalText);
  if (commandGates === "fail" && testerVerdict === "PASS") testerVerdict = "FAIL";
  // Tester hard trip → BLOCKED, never retried into a loop (the loop-breaker wins; foreman index.ts:2358).
  if (testerMonitor.hardTrip()) testerVerdict = "BLOCKED";
  ledger.log({ type: "tester", round, verdict: testerVerdict });

  progress("• reviewer");
  const reviewerPrompt =
    `${intent}\n\nReview the DIFF below for ship-risk (adversarial). End with REVIEW: APPROVE or ` +
    `REVIEW: REQUEST-CHANGES, then BLOCKING: / NITS:.\n\nDIFF:\n${diff}`;
  const reviewerRes = await crew("reviewer", reviewerPrompt);
  ledger.writeHandoff(`round-${round}-reviewer`, reviewerPrompt);
  const reviewVerdict = parseReviewVerdict(reviewerRes.finalText);
  const reviewOutcome = decideReviewOutcome(reviewVerdict);
  ledger.log({ type: "reviewer", round, verdict: reviewVerdict.decision, reopens: reviewOutcome.reopen });

  ledger.state.verdicts.push({ round, tester: testerVerdict, reviewer: reviewVerdict.decision });
  (ledger.state as any).lastCommandGates = commandGates;
  ledger.state.state = "awaiting_gate2";

  // Strict DoD rendered BY CODE (not model memory) and shown at Gate 2. gate2Approved=false here:
  // founder sign-off is the only remaining item on a clean run.
  const dod = evaluateDoneness(donenessInput(ledger, false));
  ledger.state.dodChecklist = Object.fromEntries(dod.checklist.map((c) => [c.name, c.status === "pass"]));
  ledger.state.blockers = dod.blockers;
  ledger.writeState();
  ledger.log({ type: "doneness_preview", done: dod.done, blockers: dod.blockers });

  return {
    slug, phase: "awaiting_gate2", filesChanged, commandGates,
    testerVerdict, reviewVerdict: reviewVerdict.decision, reviewReopens: reviewOutcome.reopen,
    message:
      `GATE 2 — ship review (round ${round}).\n${renderDoneChecklist(dod)}\n` +
      `Files: ${filesChanged.join(", ") || "(none reported)"}.\n\n` +
      (dod.done
        ? `Definition of Done is met except founder sign-off. `
        : `⚠ Strict DoD NOT met (${dod.blockers.join("; ")}). Approving will NOT force-ship; revise instead. `) +
      `Approve → maestro({resume:true, slug:"${slug}", gate:2, approve:true}). ` +
      `Revise → maestro({resume:true, slug:"${slug}", gate:2, reject:"<feedback>"}).`,
  };
}

// ── commit on Gate-2 approve + clean DoD (release action; path-scoped via reused ship.ts) ─────────
function runReleaseCommit(ledger: Ledger, cwd: string): { committed: boolean; detail: string } {
  const slug = ledger.state.slug;
  let isGitRepo = false;
  try { execSync("git rev-parse --is-inside-work-tree", { cwd, stdio: "ignore" }); isGitRepo = true; } catch {}
  if (!isGitRepo) return { committed: false, detail: "not a git repo" };

  // Stage the developer's changes plus the committable ledger (path-scoped; ship.ts filters unsafe
  // whole-tree pathspecs). filesLikely from the plan seeds the scope; the ledger dir is always added.
  const stagePaths = resolveStagePaths({
    filesChanged: ((ledger.readPlan() as any)?.filesLikely) ?? [],
    ledgerRelDir: `.claude/maestro/${slug}`,
  });
  for (const p of stagePaths) { try { execSync(`git add -- ${JSON.stringify(p)}`, { cwd, stdio: "ignore" }); } catch {} }
  try { execSync("git add -A", { cwd, stdio: "ignore" }); } catch {}
  const stagedCount = Number(execSync("git diff --cached --name-only", { cwd, encoding: "utf8" }).split("\n").filter(Boolean).length);

  const decision = decideShipCommit({ isGitRepo, hasReleaseCommitGate: true, stagedCount });
  if (!decision.commit) return { committed: false, detail: decision.reason };

  const msg = buildCommitMessage({
    task: ledger.state.task, slug, track: ledger.state.track,
    doneSummary: "strict DoD met; founder approved at Gate 2",
  });
  execSync("git commit -F -", { cwd, input: msg });
  return { committed: true, detail: `committed ${stagedCount} path(s)` };
}

// ── PHASE 2+: resume on a founder decision ───────────────────────────────────
export interface ResumeDecision { approve?: boolean; reject?: string; gate?: 1 | 2 }

export async function resume(slug: string, decision: ResumeDecision, opts: StartOptions): Promise<GatePayload> {
  const cwd = opts.cwd;
  const progress = (l: string) => opts.onProgress?.(l);
  if (!Ledger.exists(cwd, slug)) throw new Error(`no maestro task '${slug}' under ${cwd}`);
  const ledger = new Ledger(cwd, slug, "", "");
  const state = ledger.state.state;

  if (state === "awaiting_gate1") {
    if (decision.reject) {
      ledger.log({ type: "gate1_rejected", feedback: decision.reject });
      ledger.state.state = "halted";
      ledger.writeState();
      return { slug, phase: "halted", message: `Plan rejected: ${decision.reject}\nTask halted. Start a new task with the revised intent.` };
    }
    ledger.state.gate1Approved = true;
    ledger.log({ type: "gate1_approved" });
    ledger.writeState();
    return implementCycle(ledger, cwd, progress);
  }

  if (state === "awaiting_gate2") {
    if (decision.reject) {
      ledger.log({ type: "gate2_rejected", feedback: decision.reject });
      // reopen: another implement round, carrying the feedback into the dev context next time
      (ledger.state as any).reopenFeedback = decision.reject;
      ledger.writeState();
      return implementCycle(ledger, cwd, progress);
    }
    // Gate 2 approve → strict DoD re-check (NO force-ship bypass), then path-scoped commit.
    const dod = evaluateDoneness(donenessInput(ledger, true));
    ledger.state.dodChecklist = Object.fromEntries(dod.checklist.map((c) => [c.name, c.status === "pass"]));
    ledger.state.blockers = dod.blockers;
    if (!dod.done) {
      ledger.state.state = "awaiting_gate2"; // stays — strict mode has no force-ship
      ledger.writeState();
      ledger.log({ type: "ship_withheld", blockers: dod.blockers });
      return {
        slug, phase: "awaiting_gate2",
        message:
          `Ship WITHHELD — strict DoD not met even with founder approval (no force-ship).\n` +
          `${renderDoneChecklist(dod)}\nBlockers: ${dod.blockers.join("; ")}.\n` +
          `Revise → maestro({resume:true, slug:"${slug}", gate:2, reject:"<feedback>"}).`,
      };
    }
    ledger.state.gate2Approved = true;
    const commit = runReleaseCommit(ledger, cwd);
    ledger.state.state = "done";
    ledger.log({ type: "gate2_approved", committed: commit.committed, detail: commit.detail });
    ledger.writeState();
    return { slug, phase: "done", message: `SHIPPED — strict DoD met. Release: ${commit.detail}.` };
  }

  if (state === "done") return { slug, phase: "done", message: "Task already done." };
  if (state === "halted") return { slug, phase: "halted", message: "Task was halted." };
  throw new Error(`task '${slug}' is in non-resumable state '${state}'`);
}

// ── convenience: headless auto-approve run (used by verify; mirrors a founder approving both gates) ─
export async function runTaskAutoApprove(task: string, opts: StartOptions): Promise<GatePayload> {
  const g1 = await startTask(task, opts);
  if (g1.phase !== "awaiting_gate1") return g1;
  const g2 = await resume(g1.slug, { approve: true, gate: 1 }, opts);
  if (g2.phase !== "awaiting_gate2") return g2;
  return resume(g1.slug, { approve: true, gate: 2 }, opts);
}
