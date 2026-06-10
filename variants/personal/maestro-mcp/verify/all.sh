#!/usr/bin/env bash
# Run the full maestro-mcp verification suite. Tiers: byte-identity anchor + each milestone live.
# Requires cliproxy on :8317. The live milestones (m1/m2/m4) run real crew (minutes each).
set -u
cd "$(dirname "$0")/.."

fail=0
run() { echo "═══ $1 ═══"; node "verify/$1" || { echo ">>> $1 FAILED"; fail=1; }; echo; }

run tier2_core_identical.mjs   # decision layer byte-identical to foreman
run m7_loopbreaker.mjs         # within-round loop-breaker / drift detector (deterministic)
run m1_crew_runner.mjs         # crew over cliproxy
run m3_gate_resume.mjs         # gate/resume mechanics
run m5_routing.mjs             # multi-provider routing
run m6_tool_registry.mjs       # multi-tool platform via MCP
run m2_controller.mjs          # full loop (live, slow)
run m4_dod_commit.mjs          # strict DoD + commit + no-force-ship (live, slow)

echo "════════════════════════════════"
[ "$fail" -eq 0 ] && echo "ALL VERIFY PASS" || echo "SOME VERIFY FAILED"
exit "$fail"
