#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerPrTools } from "./tools/pr.js";
import { registerIssueTools } from "./tools/issues.js";
import { registerRepoTools } from "./tools/repo.js";
import { registerLabelTools } from "./tools/labels.js";
import { registerClaimTools } from "./tools/claims.js";

async function main(): Promise<void> {
  const server = new McpServer({
    name: "github-rest-mcp",
    version: "0.1.0",
  });

  registerPrTools(server);
  registerIssueTools(server);
  registerRepoTools(server);
  registerLabelTools(server);
  registerClaimTools(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("github-rest-mcp failed to start:", err);
  process.exit(1);
});
