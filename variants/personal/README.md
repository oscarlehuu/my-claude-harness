# personal — MCP Maestro (build later, when needed)

Use this variant when you need **process-100% enforcement** and/or **native multi-provider**
(developer=GPT-5.5, ui=Gemini) on your personal setup, via **cliproxy**.

Shape (to build):
```
personal/
  maestro-mcp/        MCP server (@modelcontextprotocol/sdk)
    server.ts         exposes the `maestro` tool
    controller.ts     coded loop dev→gate→test→review (port from my-pi-harness foreman/index.ts)
    crew-runner.ts    Agent SDK query({model}) via cliproxy  (developer=gpt-5.5, ui=gemini, tester=opus)
  .claude/
    settings.json     env: ANTHROPIC_BASE_URL=http://localhost:8317 ; hooks → ../company/.claude/hooks
    .mcp.json         register maestro-mcp + ../tools/*
```

Notes / verified facts:
- Agent SDK + cliproxy works (Claude + gpt-5.4 + gemini verified routing on subscription, no API key).
- `claude -p` / Agent SDK on subscription = **capped Agent SDK credit** (not full interactive
  allowance) — that's why this is the personal/cliproxy variant, not the default.
- The native **Workflow** path (company) draws full interactive allowance and is process-100%, so
  prefer it unless you specifically need the coded-controller's extra freedom (fs in controller,
  mid-run human gates, custom integrations).
- Crew runner: prefer Agent SDK `query()` over Bash (structured output, same engine).
- maestro MCP can be called from the main `claude` session AND from workflow/ultracode (MCP tools
  reachable via ToolSearch).
