// verify/m4_dod_commit.mjs — strict DoD (code-rendered) + release commit (M4).
// Part A (live): clean task → DoD met → path-scoped commit actually lands in git.
// Part B (seeded, deterministic): a not-done state → Gate-2 approve WITHHOLDS the commit (no
// force-ship), proving strict DoD has no bypass even with founder approval. Exit 0 = pass.

import { startTask, resume } from "../controller.ts";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

let pass = true;
const mark = (label, ok) => { console.log(`  ${ok ? "✓" : "✗"} ${label}`); if (!ok) pass = false; };

// ── Part A — live clean task → DoD met → commit ──────────────────────────────
console.log("── M4 Part A: clean task → DoD met → commit ──");
{
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m4a-"));
  execSync("git init -q && git config user.email t@t && git config user.name t", { cwd: work });
  const task = "Create util.mjs in the repo root exporting `export function double(n){return n*2}`.";
  const verifyCommand = `node -e "import('./util.mjs').then(m=>{if(m.double(4)!==8)process.exit(1);console.log('ok')}).catch(()=>process.exit(1))"`;
  const opts = { cwd: work, verifyCommand, onProgress: (l) => console.log(`[m4a] ${l}`) };
  const g1 = await startTask(task, opts);
  const g2 = await resume(g1.slug, { approve: true, gate: 1 }, opts);
  const done = await resume(g1.slug, { approve: true, gate: 2 }, opts);
  console.log(`[m4a] final phase=${done.phase} msg="${done.message.slice(0, 70)}"`);
  const state = JSON.parse(fs.readFileSync(path.join(work, ".claude/maestro", g1.slug, "state.json"), "utf8"));
  let commitCount = 0;
  try { commitCount = Number(execSync("git rev-list --count HEAD", { cwd: work, encoding: "utf8" }).trim()); } catch {}
  mark("clean task reached phase=done", done.phase === "done" && g2.phase === "awaiting_gate2");
  // DoD met = controller committed (it only commits when evaluateDoneness().done is true) AND no
  // blockers. (dodChecklist persists n/a checks as false by the plan's boolean schema, so a strict
  // all-true check is wrong — the absence of blockers is the faithful "DoD met" signal.)
  mark("dodChecklist persisted + DoD met (no blockers)", !!state.dodChecklist && Object.keys(state.dodChecklist).length >= 5 && (state.blockers ?? []).length === 0);
  mark("a commit actually landed in git (release action ran)", commitCount >= 1);
  mark("commit message references the task/DoD", (() => { try { return /strict DoD|double|util/i.test(execSync("git log -1 --format=%B", { cwd: work, encoding: "utf8" })); } catch { return false; } })());
  fs.rmSync(work, { recursive: true, force: true });
}

// ── Part B — seeded not-done state → Gate-2 approve must WITHHOLD (no force-ship) ─────────────────
console.log("\n── M4 Part B: not-done state → approve WITHHOLDS (no force-ship) ──");
{
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m4b-"));
  execSync("git init -q && git config user.email t@t && git config user.name t", { cwd: work });
  fs.writeFileSync(path.join(work, "seed.txt"), "seed\n");
  execSync("git add -A && git commit -q -m seed", { cwd: work });
  const slug = "seeded-not-done";
  const dir = path.join(work, ".claude/maestro", slug);
  fs.mkdirSync(path.join(dir, "handoffs"), { recursive: true });
  // a not-done state: tester FAIL + reviewer request-changes, command gate fail, Gate 1 approved
  fs.writeFileSync(path.join(dir, "state.json"), JSON.stringify({
    task: "seeded", slug, track: "backend", round: 1, gate1Approved: true, gate2Approved: false,
    pendingDecision: null, verdicts: [{ round: 1, tester: "FAIL", reviewer: "request-changes" }],
    dodChecklist: null, blockers: [], state: "awaiting_gate2", lastCommandGates: "fail",
  }, null, 2));
  fs.writeFileSync(path.join(dir, "plan.json"), JSON.stringify({ summary: "x", steps: [], filesLikely: [], risks: [], proposedGates: [], requirements: {} }));
  const before = Number(execSync("git rev-list --count HEAD", { cwd: work, encoding: "utf8" }).trim());
  const res = await resume(slug, { approve: true, gate: 2 }, { cwd: work });
  const after = Number(execSync("git rev-list --count HEAD", { cwd: work, encoding: "utf8" }).trim());
  const state = JSON.parse(fs.readFileSync(path.join(dir, "state.json"), "utf8"));
  console.log(`[m4b] phase=${res.phase} commitsBefore=${before} after=${after}`);
  mark("approve on not-done → stays awaiting_gate2 (withheld)", res.phase === "awaiting_gate2");
  mark("NO commit created (no force-ship bypass)", after === before);
  mark("state still gate2Approved=false", state.gate2Approved === false);
  mark("withhold message names the blockers", /WITHHELD|strict DoD/i.test(res.message));
  fs.rmSync(work, { recursive: true, force: true });
}

console.log(pass ? "\nM4 PASS" : "\nM4 FAIL");
process.exit(pass ? 0 : 1);
