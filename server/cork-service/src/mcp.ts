import { createHash } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { authorize } from "./auth.js";
import { type Principal, ServiceError, bottleSchema, lifecycle, pairingSchema, patchSchema, tastingSchema, timestamp, uuid, wineType } from "./contracts.js";
import { CellarService } from "./db.js";

function derivedID(operationID: string, label: string) {
  const bytes = createHash("sha256").update(`${operationID}:${label}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function createMCP(service: CellarService, principal: Principal, resource: string) {
  const server = new McpServer({ name: "Cork", version: "0.1.0" }, {
    instructions: "Search Cork before changing a bottle. Use returned bottle IDs and versions. Ask the user to choose when several bottles match. Never invent tasting scores. A successful write is saved on the server; the iOS app reflects it after its next sync."
  });
  function tool(name: string, description: string, inputSchema: z.ZodRawShape, write: boolean, run: (args: any) => Promise<unknown>) {
    const scope = write ? "cellar:write" : "cellar:read";
    server.registerTool(name, {
      title: name, description, inputSchema, outputSchema: { result: z.unknown() },
      annotations: { readOnlyHint: !write, destructiveHint: false, openWorldHint: false },
      _meta: { securitySchemes: [{ type: "oauth2", scopes: [scope] }] }
    }, async args => {
      try {
        authorize(principal, scope);
        const result = await run(args);
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }], structuredContent: { result } };
      } catch (error) {
        const code = error instanceof ServiceError ? error.code : error instanceof z.ZodError ? "VALIDATION_ERROR" : "INTERNAL_ERROR";
        const result = { code, ...(error instanceof ServiceError && error.current ? { current: error.current } : {}) };
        return {
          isError: true, content: [{ type: "text" as const, text: JSON.stringify(result) }], structuredContent: { result },
          ...(code === "FORBIDDEN" ? { _meta: { "mcp/www_authenticate": [`Bearer resource_metadata="${resource.replace(/\/mcp$/, "")}/.well-known/oauth-protected-resource", error="insufficient_scope", error_description="Additional permission required", scope="${scope}"`] } } : {})
        };
      }
    });
  }
  tool("search_bottles", "Corkの在庫を検索します。同名のボトルはIDで区別してください。", {
    query: z.string().max(500).optional(), wineType: wineType.optional(), state: lifecycle.optional(),
    region: z.string().max(200).optional(), vintage: z.number().int().optional(),
    afterID: uuid.optional(), limit: z.number().int().min(1).max(100).default(20)
  }, false, async args => {
    const fold = (value: string) => value.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
    const rows = (await service.list(principal.owner)).filter(({ bottleID, bottle }) =>
      (!args.afterID || bottleID > args.afterID) && (!args.wineType || bottle.wineType === args.wineType) &&
      (!args.state || bottle.lifecycleState === args.state) && (!args.vintage || bottle.vintage === args.vintage) &&
      (!args.region || fold(bottle.region ?? "").includes(fold(args.region))) &&
      (!args.query || fold([bottle.name, bottle.producer, bottle.region, bottle.country, ...bottle.grapeVarieties].join(" ")).includes(fold(args.query))));
    const page = rows.slice(0, args.limit);
    return { bottles: page.map(({ bottleID, version, bottle }) => ({ bottleID, version, name: bottle.name, vintage: bottle.vintage, wineType: bottle.wineType, state: bottle.lifecycleState })), nextID: rows.length > args.limit ? page.at(-1)?.bottleID : null };
  });
  tool("get_bottle", "Corkの個別ボトルと記録・現在のversionを確認します。履歴はページ単位で取得します。", {
    bottleID: uuid, historyOffset: z.number().int().nonnegative().max(10000).default(0),
    historyLimit: z.number().int().min(1).max(100).default(20)
  }, false, async args => {
    const result = await service.get(principal.owner, args.bottleID);
    const bottle = result.bottle!;
    const counts = { tastings: bottle.tastings.length, pairings: bottle.pairings.length, events: bottle.events.length };
    const end = args.historyOffset + args.historyLimit;
    return { ...result, bottle: { ...bottle,
      tastings: [...bottle.tastings].sort((a, b) => b.tastedAt.localeCompare(a.tastedAt)).slice(args.historyOffset, end),
      pairings: [...bottle.pairings].reverse().slice(args.historyOffset, end),
      events: [...bottle.events].sort((a, b) => b.occurredAt.localeCompare(a.occurredAt)).slice(args.historyOffset, end)
    }, historyCounts: counts, nextHistoryOffset: Math.max(...Object.values(counts)) > end ? end : null };
  });
  tool("get_sync_status", "サーバーと端末の最終同期状況を確認します。", {}, false, () => service.status(principal.owner));
  tool("get_taste_profile", "記録された評価・香り・料理の相性から好みを集計します。", {}, false, async () => {
    const bottles = await service.list(principal.owner);
    const tastings = bottles.flatMap(item => item.bottle.tastings);
    const averages = Object.fromEntries(["acidity", "sweetness", "tannin", "body"].map(key => {
      const values = tastings.map(t => t[key as "body"]).filter((v): v is number => v !== null);
      return [key, values.length ? values.reduce((a, b) => a + b, 0) / values.length : null];
    }));
    const tags = new Map<string, number>();
    for (const tasting of tastings) for (const tag of [...tasting.aromaTags, ...tasting.palateTags]) tags.set(tag, (tags.get(tag) ?? 0) + 1);
    const categories = new Map<string, number[]>();
    for (const { bottle } of bottles) for (const pairing of bottle.pairings) {
      if (pairing.dishCategory) categories.set(pairing.dishCategory, [...(categories.get(pairing.dishCategory) ?? []), pairing.score]);
    }
    return { tastingCount: tastings.length, averages, hasEnoughData: tastings.length >= 3,
      favoriteTags: [...tags].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 5).map(([tag]) => tag),
      pairingCategories: [...categories].map(([category, scores]) => ({ category, count: scores.length, averageScore: scores.reduce((a, b) => a + b, 0) / scores.length })),
      calculatedAt: new Date().toISOString() };
  });
  tool("create_bottle", "購入したワインを1本登録します。未指定の情報や評価は推測しません。再試行時は同じoperationIDを使います。", {
    operationID: uuid, name: z.string().trim().min(1).max(500), wineType,
    producer: z.string().max(500).optional(), region: z.string().max(500).optional(), country: z.string().max(500).optional(),
    vintage: z.number().int().min(1000).max(2999).optional(), grapeVarieties: z.array(z.string().max(100)).max(100).default([]),
    volumeML: z.number().int().positive().max(100000).optional(), alcoholPercent: z.number().min(0).max(100).optional(),
    storageLocation: z.string().max(10000).optional(), note: z.string().max(10000).optional()
  }, true, args => {
    const now = new Date().toISOString();
    const bottleID = derivedID(args.operationID, "bottle");
    const { operationID, ...fields } = args;
    const bottle = bottleSchema.parse({ ...fields, id: bottleID, wineID: derivedID(operationID, "wine"),
      cellarID: derivedID(principal.owner, "cellar"), lifecycleState: "owned", remainingPercent: 100,
      bottleShape: "generic", createdAt: now, updatedAt: now, tastings: [], pairings: [], events: [] });
    return service.perform(principal.owner, { operationID, bottleID, baseVersion: 0, action: { kind: "create", bottle } }, { tool: "create_bottle", args });
  });
  const writeFields = { operationID: uuid, bottleID: uuid, expectedVersion: z.number().int().nonnegative().safe() };
  tool("update_bottle", "保管場所・メモ・残量を変更します。省略項目は維持し、nullで消去します。", { ...writeFields, patch: patchSchema }, true,
    args => service.perform(principal.owner, { operationID: args.operationID, bottleID: args.bottleID, baseVersion: args.expectedVersion, action: { kind: "patch", patch: args.patch } }));
  tool("set_bottle_state", "所持・開栓中・飲了へ変更し、日付と残量と履歴を保存します。", { ...writeFields, state: lifecycle, occurredAt: timestamp.optional() }, true,
    args => service.perform(principal.owner, { operationID: args.operationID, bottleID: args.bottleID, baseVersion: args.expectedVersion, action: { kind: "state", state: args.state, occurredAt: args.occurredAt, eventID: derivedID(args.operationID, "event") } }));
  tool("add_tasting", "ユーザーが指定した飲用記録を追加します。日付・評価を推測しません。", { ...writeFields, tasting: tastingSchema.omit({ id: true }) }, true,
    args => service.perform(principal.owner, { operationID: args.operationID, bottleID: args.bottleID, baseVersion: args.expectedVersion, action: { kind: "tasting", tasting: { ...args.tasting, id: derivedID(args.operationID, "tasting") } } }));
  tool("add_pairing", "実際に食べた料理と相性の記録を追加します。", { ...writeFields, pairing: pairingSchema.omit({ id: true }) }, true,
    args => service.perform(principal.owner, { operationID: args.operationID, bottleID: args.bottleID, baseVersion: args.expectedVersion, action: { kind: "pairing", pairing: { ...args.pairing, id: derivedID(args.operationID, "pairing") } } }));
  return server;
}
