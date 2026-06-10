// verify/tier2_core_identical.mjs — fidelity anchor (tier 2).
// Proves every module under core/ is BYTE-IDENTICAL to its pi-foreman source. Byte-identical means
// the decision layer isn't "faithfully ported" — it is literally the same code foreman's own 17
// test/*.sh validate. Run: node verify/tier2_core_identical.mjs
//
// If a module DIFFERS, either foreman changed (re-sync) or core/ was edited (it must not be — the
// decision layer is reused, not forked). Diff output shows what drifted.

import * as fs from "node:fs";
import * as path from "node:path";
import { execSync } from "node:child_process";

const here = path.dirname(new URL(import.meta.url).pathname);
const coreDir = path.join(here, "..", "core");
const foremanDir = "/Users/a1241968/Desktop/Oscar/my-pi-harness/extensions/foreman";

const modules = fs.readdirSync(coreDir).filter((f) => f.endsWith(".ts"));
let identical = 0;
const drift = [];

for (const m of modules) {
  const a = path.join(coreDir, m);
  const b = path.join(foremanDir, m);
  if (!fs.existsSync(b)) { drift.push(`${m}: NO foreman source`); continue; }
  try {
    execSync(`diff -q ${JSON.stringify(b)} ${JSON.stringify(a)}`, { stdio: "ignore" });
    identical++;
  } catch {
    drift.push(`${m}: DIFFERS from foreman source`);
  }
}

console.log("── Tier-2 fidelity anchor: core/ vs pi-foreman ──");
console.log(`  ${identical}/${modules.length} modules byte-identical`);
for (const d of drift) console.log(`  ✗ ${d}`);

const pass = drift.length === 0;
console.log(pass ? "\nTIER-2 PASS (decision layer is byte-identical, not just faithful)" : "\nTIER-2 FAIL");
process.exit(pass ? 0 : 1);
