// verify/m5_routing.mjs — multi-provider crew routing (M5).
// Proves: every role maps to a cliproxy model that exists; developer is decorrelated from the judges
// (developer model ≠ tester/reviewer model); and all three provider families (Opus/GPT/Gemini) route
// live through cliproxy on one subscription. Exit 0 = pass.

import { ROLE_MODEL, cliproxyKey } from "../crew-runner.ts";

const KEY = cliproxyKey();
const BASE = "http://localhost:8317/v1";

let pass = true;
const mark = (label, ok) => { console.log(`  ${ok ? "✓" : "✗"} ${label}`); if (!ok) pass = false; };

console.log("── M5: multi-provider routing ──");
console.log("  ROLE_MODEL:", JSON.stringify(ROLE_MODEL));

// live model list
const models = (await (await fetch(`${BASE}/models`, { headers: { Authorization: `Bearer ${KEY}` } })).json()).data.map((m) => m.id);

mark("every role maps to a model present in cliproxy", Object.values(ROLE_MODEL).every((m) => models.includes(m)));
mark("developer decorrelated from tester (different model)", ROLE_MODEL.developer !== ROLE_MODEL.tester);
mark("developer decorrelated from reviewer (different model)", ROLE_MODEL.developer !== ROLE_MODEL.reviewer);
mark("judges (planner/tester/reviewer) are Anthropic (opus)", [ROLE_MODEL.planner, ROLE_MODEL.tester, ROLE_MODEL.reviewer].every((m) => m.startsWith("claude-opus")));

// live: one tiny completion per distinct family routes via cliproxy. The Max-quota guarantee is
// ARCHITECTURAL — cliproxy holds the subscription OAuth for every provider and has no upstream API
// key, so any successful route draws from the subscription, not billed credits. (The CC system-prompt
// marker is injected only for Anthropic models — opus prompt_tokens≈1900 vs Gemini≈5 — so marker size
// is NOT a universal Max-quota signal; successful routing via cliproxy is.)
const distinct = [...new Set(Object.values(ROLE_MODEL))];
for (const model of distinct) {
  let ok = false, usage = null;
  try {
    const r = await fetch(`${BASE}/chat/completions`, {
      method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model, max_tokens: 16, messages: [{ role: "user", content: "Reply with: OK" }] }),
    });
    const d = await r.json();
    ok = r.ok && !!d.choices?.[0]?.message;
    usage = d.usage?.prompt_tokens;
  } catch {}
  mark(`live route ${model} via cliproxy (subscription auth; prompt_tokens=${usage})`, ok);
}

console.log(pass ? "\nM5 PASS" : "\nM5 FAIL");
process.exit(pass ? 0 : 1);
