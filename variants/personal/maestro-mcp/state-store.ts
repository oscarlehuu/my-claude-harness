// state-store.ts — maestro task ledger (plan §8). Durable state under
// .claude/maestro/<slug>/ so a crash/restart resumes from state.json. This is maestro-specific
// storage (the path differs from pi foreman's .pi/plans/<slug>/); the DECISION layer it records is
// the reused, byte-identical foreman core. Checkpoint after every round → long-running resilience.

import * as fs from "node:fs";
import * as path from "node:path";

export interface TaskState {
  task: string;
  slug: string;
  track: string;
  round: number;
  planSource?: "planner" | "fallback";
  gate1Approved: boolean;
  gate2Approved: boolean;
  pendingDecision: unknown | null;
  verdicts: Array<{ round: number; tester: string | null; reviewer: string | null }>;
  dodChecklist: Record<string, boolean> | null;
  blockers: string[];
  state: "planning" | "implementing" | "awaiting_gate1" | "awaiting_gate2" | "done" | "halted";
}

export function slugify(task: string): string {
  return task.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "task";
}

export class Ledger {
  readonly dir: string;
  readonly state: TaskState;
  constructor(cwd: string, slug: string, task: string, track: string) {
    this.dir = path.join(cwd, ".claude", "maestro", slug);
    fs.mkdirSync(path.join(this.dir, "handoffs"), { recursive: true });
    const statePath = path.join(this.dir, "state.json");
    if (fs.existsSync(statePath)) {
      this.state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    } else {
      this.state = {
        task, slug, track, round: 0, gate1Approved: false, gate2Approved: false,
        pendingDecision: null, verdicts: [], dodChecklist: null, blockers: [], state: "planning",
      };
      this.writeState();
    }
  }

  writeState(): void {
    fs.writeFileSync(path.join(this.dir, "state.json"), JSON.stringify(this.state, null, 2));
  }

  log(event: Record<string, unknown>): void {
    const line = JSON.stringify({ t: new Date().toISOString(), ...event }) + "\n";
    fs.appendFileSync(path.join(this.dir, "log.jsonl"), line);
  }

  writePlan(plan: unknown, planMd: string): void {
    fs.writeFileSync(path.join(this.dir, "plan.json"), JSON.stringify(plan, null, 2));
    fs.writeFileSync(path.join(this.dir, "plan.md"), planMd);
  }

  readPlan(): any {
    const p = path.join(this.dir, "plan.json");
    return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : null;
  }

  static exists(cwd: string, slug: string): boolean {
    return fs.existsSync(path.join(cwd, ".claude", "maestro", slug, "state.json"));
  }

  writeHandoff(name: string, content: string): void {
    fs.writeFileSync(path.join(this.dir, "handoffs", `${name}.md`), content);
  }
}
