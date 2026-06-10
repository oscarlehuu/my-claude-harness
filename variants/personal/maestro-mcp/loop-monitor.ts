// loop-monitor.ts — maestro wiring for the within-round crew loop-breaker.
//
// This is the maestro equivalent of foreman's `createLoopRunMonitor` (my-pi-harness/extensions/
// foreman/index.ts:522). The DETECTOR is the byte-identical pure module core/loopbreaker.ts; this
// file is the impure glue that lives outside it (foreman keeps the same split — detection in
// loopbreaker.ts, abort+ledger wiring in index.ts). It feeds crew tool telemetry into the detector
// and, on a HARD trip, aborts the run via an AbortController and records it to the ledger. A SOFT
// trip only logs a one-per-signature warning (the headless crew run cannot receive feedback
// mid-flight — only the NEXT attempt's prompt can carry a re-plan note), faithfully mirroring the
// foreman NEVER boundaries (INTERNALS §09: soft never aborts/injects; hard aborts; never infinite-loop).

import * as fs from "node:fs";
import * as path from "node:path";
import { createLoopDetector, parseLoopBreakerEnv, type LoopToolEvent, type LoopVerdict } from "./core/loopbreaker.ts";

// Parsed once from FOREMAN_LOOP_SOFT / FOREMAN_LOOP_HARD (hard floored to >= soft), exactly as
// foreman does at index.ts:98. Defaults: soft 3 / hard 5.
const LOOP_BREAKER_THRESHOLDS = parseLoopBreakerEnv(process.env);

export function loopVerdictSummary(verdict: LoopVerdict): string {
  return verdict.summary ?? `${verdict.pattern ?? "loop"}: ${verdict.signature ?? "unknown signature"}`;
}

export interface LoopRunMonitor {
  readonly signal: AbortSignal;
  onToolEvent: (event: LoopToolEvent) => void;
  hardTrip: () => LoopVerdict | null;
  dispose: () => void;
}

export interface LoopMonitorOptions {
  role: string;
  round: number;
  log: (event: Record<string, unknown>) => void; // ledger.log seam
  parentSignal?: AbortSignal; // outer abort (founder cancel / timeout) cascades into this run
}

// Create a within-run loop monitor: detector + AbortController + ledger logging.
export function createLoopRunMonitor(opts: LoopMonitorOptions): LoopRunMonitor {
  const detector = createLoopDetector(LOOP_BREAKER_THRESHOLDS);
  const controller = new AbortController();
  const warned = new Set<string>(); // soft trips: warn once per signature
  let hardTrip: LoopVerdict | null = null;

  const onParentAbort = () => controller.abort();
  if (opts.parentSignal) {
    if (opts.parentSignal.aborted) controller.abort();
    else opts.parentSignal.addEventListener("abort", onParentAbort, { once: true });
  }

  return {
    signal: controller.signal,
    onToolEvent(event: LoopToolEvent) {
      const verdict = detector.observe(event);
      if (!verdict.tripped) return;
      const summary = loopVerdictSummary(verdict);
      if (verdict.severity === "hard") {
        // HARD: record once, abort the run. The next attempt carries a LOOP DETECTED re-plan note.
        if (!hardTrip) {
          hardTrip = verdict;
          opts.log({ type: "loop_detected", role: opts.role, round: opts.round, pattern: verdict.pattern, signature: verdict.signature, summary });
          controller.abort();
        }
        return;
      }
      // SOFT: early visibility only — never aborts, never injects mid-flight.
      const sig = verdict.signature ?? summary;
      if (!warned.has(sig)) {
        warned.add(sig);
        opts.log({ type: "loop_warning", role: opts.role, round: opts.round, pattern: verdict.pattern, signature: verdict.signature, summary });
      }
    },
    hardTrip: () => hardTrip,
    dispose() {
      if (opts.parentSignal) opts.parentSignal.removeEventListener("abort", onParentAbort);
    },
  };
}

// Count how many DISTINCT rounds a given hard-trip signature has been recorded against in the ledger
// log. Mirrors foreman's loopHardTripRoundCount (index.ts:581): when the SAME signature hard-trips in
// 2 different rounds, the orchestrator stops retrying and escalates — never infinite-loops a stuck role.
export function countHardTripRounds(ledgerDir: string, signature: string | undefined): number {
  if (!signature) return 0;
  const logPath = path.join(ledgerDir, "log.jsonl");
  if (!fs.existsSync(logPath)) return 0;
  const rounds = new Set<number>();
  for (const line of fs.readFileSync(logPath, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const ev = JSON.parse(line);
      if (ev.type === "loop_detected" && ev.signature === signature && typeof ev.round === "number") rounds.add(ev.round);
    } catch { /* skip malformed line */ }
  }
  return rounds.size;
}
