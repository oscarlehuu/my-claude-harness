// verify/m6_tool_registry.mjs — multi-tool harness platform (M6).
// Spawns the real MCP server over stdio and proves: the registry advertises >1 tool (maestro +
// maestro-status), and a second tool actually executes through the MCP protocol (maestro-status
// returns a seeded task's state). This is the "register any harness" extensibility. Exit 0 = pass.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const serverPath = path.join(here, "..", "server.ts");

// seed a task state in a temp cwd so maestro-status has something to read
const work = fs.mkdtempSync(path.join(os.tmpdir(), "maestro-m6-"));
const slug = "seeded-task";
const dir = path.join(work, ".claude", "maestro", slug);
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "state.json"), JSON.stringify({
  task: "seeded", slug, track: "backend", round: 2, gate1Approved: true, gate2Approved: false,
  pendingDecision: null, verdicts: [{ round: 1, tester: "FAIL", reviewer: "request-changes" }, { round: 2, tester: "PASS", reviewer: "approve" }],
  dodChecklist: { "Plan approval": true }, blockers: [], state: "awaiting_gate2",
}));

const proc = spawn("node", [serverPath], { cwd: work, stdio: ["pipe", "pipe", "ignore"] });
const responses = new Map();
let buf = "";
proc.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    try { const m = JSON.parse(line); if (m.id != null) responses.set(m.id, m); } catch {}
  }
});
const send = (msg) => proc.stdin.write(JSON.stringify(msg) + "\n");
const waitFor = (id, ms = 8000) => new Promise((res, rej) => {
  const t0 = Date.now();
  const iv = setInterval(() => {
    if (responses.has(id)) { clearInterval(iv); res(responses.get(id)); }
    else if (Date.now() - t0 > ms) { clearInterval(iv); rej(new Error(`timeout waiting for id ${id}`)); }
  }, 30);
});

let pass = true;
const mark = (label, ok) => { console.log(`  ${ok ? "✓" : "✗"} ${label}`); if (!ok) pass = false; };

try {
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "m6", version: "0" } } });
  await waitFor(1);
  send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  const list = await waitFor(2);
  const names = (list.result?.tools ?? []).map((t) => t.name);
  console.log("  tools advertised:", names.join(", "));

  send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "maestro-status", arguments: { slug } } });
  const call = await waitFor(3);
  const text = call.result?.content?.[0]?.text ?? "";

  mark("registry advertises >1 tool (extensibility)", names.length >= 2);
  mark("both maestro and maestro-status are registered", names.includes("maestro") && names.includes("maestro-status"));
  mark("second tool executes via MCP protocol (maestro-status)", /phase=awaiting_gate2/.test(text));
  mark("maestro-status returns the seeded verdicts", /"tester":\s*"PASS"/.test(text) && /round=2/.test(text));
} catch (e) {
  console.log("  ✗ error:", e.message); pass = false;
} finally {
  proc.kill();
  fs.rmSync(work, { recursive: true, force: true });
}

console.log(pass ? "\nM6 PASS" : "\nM6 FAIL");
process.exit(pass ? 0 : 1);
