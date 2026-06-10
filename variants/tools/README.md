# tools — utility MCP servers (port from my-pi-harness)

The API-client tools from my-pi-harness become standalone MCP servers, usable by both variants and
by any MCP client (Claude Code, workflow/ultracode, Cursor, …).

To port (each = its own MCP server, `@modelcontextprotocol/sdk`):
```
tools/
  grok-mcp/          grok-web-search, x-search, imagine   (port extensions/grok/_shared/grokClient.ts)
  codex-image-mcp/   generate + edit                       (port extensions/codex/_shared/codexImageClient.ts)
  antigravity-mcp/   imagegen + imageedit                  (port extensions/antigravity/_shared/antigravityClient.ts)
```

Each is the cleanest port: the `_shared/*Client.ts` are pure HTTP/OAuth clients (node builtins, no
pi runtime) → wrap each tool in an MCP `tool` handler; keep their own auth (read ~/.grok, Codex
OAuth, etc. — no Claude billing). Register via `.mcp.json`.
