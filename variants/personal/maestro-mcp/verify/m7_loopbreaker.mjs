// verify/m7_loopbreaker.mjs — within-round loop-breaker / drift detector (M7).
// Deterministic (NO live cliproxy): proves the three layers wired this milestone —
//   1. core/loopbreaker.ts  — the byte-identical pure detector behaves (sanity).
//   2. loop-monitor.ts      — soft warns once/signature & never aborts; hard logs + aborts the signal.
//   3. crew-runner.ts       — the REAL transport aborts mid-run when the monitor hard-trips (stubbed
//                             fetch returns an identical tool-call forever → loop-breaker cuts it
//                             short, well before the step cap). This is the integration seam.
//   4. countHardTripRounds  — cross-round escalation counter (never infinite-loop a stuck role).
// Exit 0 = pass.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createLoopDetector } from "../core/loopbreaker.ts";
import { createLoopRunMonitor, countHardTripRounds } from "../loop-monitor.ts";
import { runCrew } from "../crew-runner.ts";

const checks = [];
const check = (label, ok) => { checks.push([label, ok]); };

// ── 1. pure detector sanity (the byte-identical module is already tier-2 proven; spot-check behavior) ──
{
  const d = createLoopDetector();
  const call = (args) => d.observe({ kind: "tool_call", name: "bash", args });
  call({ command: "npm test" }); call({ command: "npm test" });
  check("detector: 3rd identical call soft-trips", call({ command: "npm test" }).severity === "soft");
  call({ command: "npm test" });
  check("detector: 5th identical call hard-trips", call({ command: "npm test" }).severity === "hard");
}

// ── 2. loop-monitor glue: soft warns once/signature & never aborts; hard logs + aborts ──
{
  const logs = [];
  const mon = createLoopRunMonitor({ role: "developer", round: 1, log: (e) => logs.push(e) });
  const ev = { kind: "tool_call", name: "bash", args: { command: "npm test" } };
  mon.onToolEvent(ev); mon.onToolEvent(ev);       // calls 1,2 — no trip
  mon.onToolEvent(ev);                             // call 3 — SOFT
  mon.onToolEvent(ev);                             // call 4 — SOFT (same signature)
  check("monitor: SOFT logs exactly one loop_warning per signature", logs.filter((e) => e.type === "loop_warning").length === 1);
  check("monitor: SOFT never aborts the run", mon.signal.aborted === false && mon.hardTrip() === null);
  mon.onToolEvent(ev);                             // call 5 — HARD
  check("monitor: HARD logs a loop_detected event", logs.filter((e) => e.type === "loop_detected").length === 1);
  check("monitor: HARD aborts the run signal", mon.signal.aborted === true);
  check("monitor: hardTrip() returns the hard verdict", mon.hardTrip()?.severity === "hard" && mon.hardTrip()?.pattern === "identical_tool_call");
  mon.dispose();
}

// parentSignal cascade: an outer abort propagates into a fresh monitor's signal.
{
  const parent = new AbortController();
  const mon = createLoopRunMonitor({ role: "tester", round: 1, log: () => {}, parentSignal: parent.signal });
  check("monitor: parent abort cascades (pre-trigger)", mon.signal.aborted === false);
  parent.abort();
  check("monitor: parent abort cascades into the run signal", mon.signal.aborted === true);
  mon.dispose();
}

// ── 3. crew-runner abort wiring: a model stuck on an identical tool-call is cut short by the monitor ──
{
  const realFetch = globalThis.fetch;
  let modelCalls = 0;
  // Stub cliproxy: always return ONE identical read_file tool-call (fast, no shell side effects;
  // read of a nonexistent path returns an ERROR string — fine, identical_tool_call trips regardless).
  globalThis.fetch = async () => {
    modelCalls++;
    return {
      ok: true,
      json: async () => ({
        choices: [{
          finish_reason: "tool_calls",
          message: { role: "assistant", content: "", tool_calls: [
            { id: `c${modelCalls}`, function: { name: "read_file", arguments: JSON.stringify({ path: "does-not-exist-loop.txt" }) } },
          ] },
        }],
      }),
    };
  };

  const logs = [];
  const monitor = createLoopRunMonitor({ role: "developer", round: 1, log: (e) => logs.push(e) });
  let result;
  try {
    result = await runCrew("developer", "Loop forever on the same read.", {
      cwd: os.tmpdir(),
      apiKey: "test-key",               // skip ~/cliproxyapi/config.yaml read
      onToolEvent: monitor.onToolEvent, // feed the detector
      signal: monitor.signal,           // obey the hard-trip abort
    });
  } finally {
    globalThis.fetch = realFetch;
  }

  check("crew-runner: stuck run stops with stoppedReason 'aborted'", result.stoppedReason === "aborted");
  check("crew-runner: loop-breaker cut it short (steps well under the 40 step cap)", result.steps < 40 && result.steps <= 6);
  check("crew-runner: aborted at the hard threshold (5 identical tool calls)", result.toolCalls === 5);
  check("crew-runner: monitor recorded a hard trip + loop_detected", monitor.hardTrip()?.severity === "hard" && logs.some((e) => e.type === "loop_detected"));
  monitor.dispose();
}

// ── 4. cross-round escalation counter ──
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m7-"));
  const lines = [
    { type: "loop_detected", round: 1, signature: "sig-X" },
    { type: "loop_detected", round: 2, signature: "sig-X" }, // SAME signature, different round → escalate
    { type: "loop_detected", round: 1, signature: "sig-Y" },
    { type: "tester", round: 2, verdict: "PASS" },
  ];
  fs.writeFileSync(path.join(dir, "log.jsonl"), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  check("countHardTripRounds: same signature across 2 rounds → 2 (triggers escalation)", countHardTripRounds(dir, "sig-X") === 2);
  check("countHardTripRounds: single-round signature → 1", countHardTripRounds(dir, "sig-Y") === 1);
  check("countHardTripRounds: unseen signature → 0", countHardTripRounds(dir, "sig-Z") === 0);
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
}

console.log("── M7 verification (loop-breaker / drift detector) ──");
let pass = true;
for (const [label, ok] of checks) { console.log(`  ${ok ? "✓" : "✗"} ${label}`); if (!ok) pass = false; }
console.log(pass ? "\nM7 PASS" : "\nM7 FAIL");
process.exit(pass ? 0 : 1);
