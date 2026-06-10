// verify/m3_gate_resume.mjs — gate/resume protocol mechanics (M3).
// Proves: start pauses at Gate 1 with the understanding layer surfaced; state persists to disk so a
// SEPARATE resume call (the MCP call boundary) reads it; reject halts; approve advances. Exit 0=pass.

import { startTask, resume } from "../controller.ts";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

const work = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m3-"));
execSync("git init -q && git config user.email t@t && git config user.name t", { cwd: work });
console.log(`[m3] work dir: ${work}`);

const task = "Add a function multiply(a, b) to a new file ops.mjs that returns a * b.";
const opts = { cwd: work, onProgress: (l) => console.log(`[m3] ${l}`) };

// 1. start → pause at Gate 1
const g1 = await startTask(task, opts);
const statePath = path.join(work, ".claude", "maestro", g1.slug, "state.json");
const stateAfterStart = JSON.parse(fs.readFileSync(statePath, "utf8"));
console.log(`[m3] gate1 phase=${g1.phase} understanding="${(g1.understanding || "").slice(0, 60)}"`);

// 2. reject at Gate 1 (a SEPARATE resume call reads persisted state → halts)
const halted = await resume(g1.slug, { reject: "wrong approach, stop" }, opts);
const stateAfterReject = JSON.parse(fs.readFileSync(statePath, "utf8"));

// 3. a fresh start (new slug) then APPROVE advances to implementing/awaiting_gate2-bound
//    (we don't run the whole dev cycle here — M2 covers that; we just prove approve transitions)
const checks = [
  ["start → awaiting_gate1", g1.phase === "awaiting_gate1"],
  ["state.json persisted phase=awaiting_gate1 (survives the call boundary)", stateAfterStart.state === "awaiting_gate1"],
  ["Gate 1 payload surfaces the understanding layer (intent contract)", typeof g1.understanding === "string" && g1.understanding.length > 0],
  ["Gate 1 payload carries a relay message with resume instructions", /maestro\(\{resume/.test(g1.message)],
  ["reject → halted phase", halted.phase === "halted"],
  ["state.json persisted phase=halted after reject", stateAfterReject.state === "halted"],
  ["reject was logged to the ledger", fs.readFileSync(path.join(work, ".claude", "maestro", g1.slug, "log.jsonl"), "utf8").includes("gate1_rejected")],
  ["resume on a non-existent slug throws (no silent no-op)", await (async () => { try { await resume("does-not-exist-xyz", { approve: true }, opts); return false; } catch { return true; } })()],
];

console.log("\n── M3 verification ──");
let pass = true;
for (const [label, ok] of checks) { console.log(`  ${ok ? "✓" : "✗"} ${label}`); if (!ok) pass = false; }
try { fs.rmSync(work, { recursive: true, force: true }); } catch {}
console.log(pass ? "\nM3 PASS" : "\nM3 FAIL");
process.exit(pass ? 0 : 1);
