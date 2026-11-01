import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMCP } from "../src/mcp.js";
import { CellarService } from "../src/db.js";
import { database } from "./helpers.js";

test("MCP advertises tools, prevents scope escalation and retries create exactly once", async t => {
  const db = await database(); t.after(() => db.close());
  const owner = randomUUID();
  async function connect(scopes: string[]) {
    const server = createMCP(new CellarService(db), { owner, scopes: new Set(scopes) }, "https://cork.example/mcp");
    const client = new Client({ name: "test", version: "1" });
    const [a, b] = InMemoryTransport.createLinkedPair();
    await server.connect(a); await client.connect(b);
    t.after(async () => { await client.close(); await server.close(); });
    return client;
  }
  const reader = await connect(["cellar:read"]);
  const tools = await reader.listTools();
  assert.equal(tools.tools.length, 9);
  assert.equal(tools.tools.find(tool => tool.name === "search_bottles")?.annotations?.readOnlyHint, true);
  const args = { operationID: randomUUID(), name: "Test Wine", wineType: "red" };
  assert.equal((await reader.callTool({ name: "create_bottle", arguments: args })).isError, true);
  const writer = await connect(["cellar:read", "cellar:write"]);
  const first = await writer.callTool({ name: "create_bottle", arguments: args });
  const retry = await writer.callTool({ name: "create_bottle", arguments: args });
  assert.equal(first.isError, undefined);
  assert.deepEqual(retry.structuredContent, first.structuredContent);
  assert.equal((await new CellarService(db).list(owner)).length, 1);
});
