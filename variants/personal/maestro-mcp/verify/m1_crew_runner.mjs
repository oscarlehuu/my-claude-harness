// verify/m1_crew_runner.mjs — LIVE verification of M1 (crew-runner over cliproxy).
//
// Proves: a developer-role agent driven by crew-runner.ts (1) talks to cliproxy (Max quota path,
// no claude -p / Agent SDK), (2) runs the OpenAI tool loop, (3) actually mutates the working tree.
// Exit 0 = pass; non-zero = fail. Run: node verify/m1_crew_runner.mjs

import { runCrew } from "../crew-runner.ts";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const work = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m1-"));
let calledModel = false;
let executedTool = false;

const goal = `GOAL: Create a file named hello.ts in the repo root that, when run with node, prints exactly: Hello, Maestro
CONTEXT TO READ FIRST: none (empty repo).
DELIVERABLES: 1) hello.ts containing a single console.log statement printing "Hello, Maestro".
CONSTRAINTS / NON-GOALS: do not create any other files; no package.json.
ACCEPTANCE / VERIFY: \`node hello.ts\` prints "Hello, Maestro".
When done, end your reply with a line: ## Completed`;

console.log(`[m1] work dir: ${work}`);
const res = await runCrew("developer", goal, {
  cwd: work,
  stepCap: 12,
  onEvent: (ev) => {
    if (ev.kind === "model_call") calledModel = true;
    if (ev.kind === "tool_call") { executedTool = true; console.log(`[m1] tool_call ${ev.name} ${ev.preview ?? ""}`); }
    if (ev.kind === "tool_result") console.log(`[m1] tool_result ${ev.name}: ${ev.preview ?? ""}`);
    if (ev.kind === "error") console.log(`[m1] ERROR: ${ev.preview ?? ""}`);
  },
});

console.log(`[m1] model=${res.model} steps=${res.steps} toolCalls=${res.toolCalls} stopped=${res.stoppedReason}`);
console.log(`[m1] final: ${res.finalText.slice(0, 200)}`);

// ── assertions ────────────────────────────────────────────────────────────────
const checks = [];
const helloPath = path.join(work, "hello.ts");
const exists = fs.existsSync(helloPath);
const content = exists ? fs.readFileSync(helloPath, "utf8") : "";
let runs = "";
if (exists) {
  try { runs = (await import("node:child_process")).execSync(`node ${helloPath}`, { encoding: "utf8" }).trim(); } catch (e) { runs = `RUN-ERROR: ${e.message}`; }
}

checks.push(["crew-runner called cliproxy model", calledModel]);
checks.push(["crew executed at least one tool", executedTool]);
checks.push(["hello.ts was written to the tree", exists]);
checks.push(["hello.ts prints 'Hello, Maestro'", runs === "Hello, Maestro"]);
checks.push(["stopped cleanly (not step_cap/error)", res.stoppedReason === "stop"]);

console.log("\n── M1 verification ──");
let pass = true;
for (const [label, ok] of checks) {
  console.log(`  ${ok ? "✓" : "✗"} ${label}`);
  if (!ok) pass = false;
}
if (runs && runs !== "Hello, Maestro") console.log(`  (actual run output: ${JSON.stringify(runs)})`);

// cleanup
try { fs.rmSync(work, { recursive: true, force: true }); } catch {}

console.log(pass ? "\nM1 PASS" : "\nM1 FAIL");
process.exit(pass ? 0 : 1);
