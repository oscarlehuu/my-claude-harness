// server.ts — MCP server exposing the harness tool registry to Claude Code. The CTO (main `claude`
// session) invokes these tools; the server owns the coded loop (controller.ts) and runs crew over
// cliproxy. Each maestro call does one phase and returns a founder-facing gate payload; the CTO
// relays Gate 1 / Gate 2 via AskUserQuestion and calls back with {resume, slug, approve|reject}.
//
// Tools come from tool-registry.ts (the "pi feeling" extensibility layer) — add harnesses there, not
// here. Register in Claude Code via .mcp.json (stdio) with a raised per-call timeout (a Gate-1-approve
// resume runs a full dev→test→review cycle, minutes): { "timeout": 600000 }. See README.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { getTools } from "./tool-registry.ts";

const server = new Server({ name: "maestro", version: "0.1.0" }, { capabilities: { tools: {} } });

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: getTools().map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = getTools().find((t) => t.name === req.params.name);
  if (!tool) return { content: [{ type: "text", text: `unknown tool: ${req.params.name}` }], isError: true };
  try {
    const r = await tool.handler((req.params.arguments ?? {}) as Record<string, any>);
    return { content: [{ type: "text", text: r.text }], ...(r.isError ? { isError: true } : {}) };
  } catch (e: any) {
    return { content: [{ type: "text", text: `${req.params.name} error: ${e?.message ?? String(e)}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
process.stderr.write(`maestro-mcp server connected (stdio) — tools: ${getTools().map((t) => t.name).join(", ")}\n`);
