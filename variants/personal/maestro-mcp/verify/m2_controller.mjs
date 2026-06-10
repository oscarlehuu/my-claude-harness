// verify/m2_controller.mjs — LIVE end-to-end of the controller loop via the phased API
// (start → Gate1 approve → Gate2 approve). Proves scope→plan→dev→command-gate→tester→reviewer on
// real crew (cliproxy), reusing foreman decision modules, producing a working change. Exit 0 = pass.

import { startTask, resume } from "../controller.ts";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

const work = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m2-"));
execSync("git init -q && git config user.email t@t && git config user.name t", { cwd: work });
console.log(`[m2] work dir: ${work}`);

const task = "Create a file math.mjs in the repo root that exports `export function add(a, b) { return a + b }`.";
const verifyCommand = `node -e "import('./math.mjs').then(m=>{if(m.add(2,3)!==5){process.exit(1)}console.log('ok')}).catch(()=>process.exit(1))"`;
const opts = { cwd: work, verifyCommand, onProgress: (l) => console.log(`[m2] ${l}`) };

const g1 = await startTask(task, opts);
console.log(`[m2] gate1: phase=${g1.phase} planSource=${g1.planSource}`);
const g2 = await resume(g1.slug, { approve: true, gate: 1 }, opts);
console.log(`[m2] gate2: phase=${g2.phase} tester=${g2.testerVerdict} reviewer=${g2.reviewVerdict} gates=${g2.commandGates}`);
const done = await resume(g1.slug, { approve: true, gate: 2 }, opts);
console.log(`[m2] final: phase=${done.phase}`);

const ledgerDir = path.join(work, ".claude", "maestro", g1.slug);
const mathPath = path.join(work, "math.mjs");
let addWorks = false;
if (fs.existsSync(mathPath)) { try { addWorks = (await import(mathPath)).add(2, 3) === 5; } catch {} }

const checks = [
  ["start → awaiting_gate1 with a plan", g1.phase === "awaiting_gate1" && (g1.planSource === "planner" || g1.planSource === "fallback")],
  ["planner emitted real foreman PLAN-JSON (not fallback)", g1.planSource === "planner"],
  ["Gate1 approve → awaiting_gate2", g2.phase === "awaiting_gate2"],
  ["developer produced filesChanged", Array.isArray(g2.filesChanged) && g2.filesChanged.length > 0],
  ["math.mjs written and add(2,3)===5 (real impl)", addWorks],
  ["command gate ran and passed (exit code ground truth)", g2.commandGates === "pass"],
  ["tester produced a verdict", ["PASS", "FAIL", "PARTIAL", "BLOCKED"].includes(g2.testerVerdict)],
  ["reviewer produced a verdict", ["approve", "request-changes", "unknown"].includes(g2.reviewVerdict)],
  ["Gate2 approve → done", done.phase === "done"],
  ["ledger state.json + log.jsonl + plan.json written", ["state.json", "log.jsonl", "plan.json"].every((f) => fs.existsSync(path.join(ledgerDir, f)))],
];

console.log("\n── M2 verification ──");
let pass = true;
for (const [label, ok] of checks) { console.log(`  ${ok ? "✓" : "✗"} ${label}`); if (!ok) pass = false; }
try { fs.rmSync(work, { recursive: true, force: true }); } catch {}
console.log(pass ? "\nM2 PASS" : "\nM2 FAIL");
process.exit(pass ? 0 : 1);
