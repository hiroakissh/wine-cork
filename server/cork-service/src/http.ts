import express, { type ErrorRequestHandler } from "express";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { authorize, type VerifyToken } from "./auth.js";
import { type Principal, ServiceError, uuid } from "./contracts.js";
import { CellarService } from "./db.js";
import { createMCP } from "./mcp.js";

export function createApp(service: CellarService, verify: VerifyToken, config: { resource: string; issuer: string }) {
  const app = express();
  const resourceURL = new URL(config.resource);
  const metadataURL = `${resourceURL.origin}/.well-known/oauth-protected-resource`;
  app.disable("x-powered-by");
  app.use((req, res, next) => {
    if (req.hostname !== resourceURL.hostname) { res.sendStatus(403); return; }
    const origin = req.get("origin");
    if (origin && ![resourceURL.origin, "https://chatgpt.com"].includes(origin)) { res.sendStatus(403); return; }
    res.set("Cache-Control", "no-store");
    next();
  });
  app.use(express.json({ limit: "4mb" }));
  app.get("/health", (_req, res) => res.json({ status: "ok" }));
  app.get(["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"], (_req, res) => res.json({
    resource: config.resource, authorization_servers: [config.issuer], scopes_supported: ["cellar:read", "cellar:write"]
  }));
  app.use(async (req, res, next) => {
    try {
      const match = /^Bearer (\S+)$/.exec(req.get("authorization") ?? "");
      if (!match?.[1]) throw new ServiceError("AUTH_REQUIRED", 401);
      res.locals.principal = await verify(match[1]);
      next();
    } catch (error) { next(error); }
  });
  const principal = (res: express.Response) => res.locals.principal as Principal;
  const requireScope = (scope: string) => (_req: express.Request, res: express.Response, next: express.NextFunction) => {
    try { authorize(principal(res), scope); next(); } catch (error) { next(error); }
  };
  app.get("/v1/profile", requireScope("cellar:read"), (_req, res) => res.json({ id: principal(res).owner }));
  app.post("/v1/operations", requireScope("cellar:write"), async (req, res) => res.json(await service.perform(principal(res).owner, req.body)));
  const cursor = z.coerce.number().int().nonnegative().safe();
  app.get("/v1/changes", requireScope("cellar:read"), async (req, res) => {
    const query = z.object({ after: cursor.default(0), until: cursor.optional(), limit: z.coerce.number().int().min(1).max(100).default(50) }).strict().parse(req.query);
    res.json(await service.changes(principal(res).owner, query.after, query.until, query.limit));
  });
  app.get("/v1/bottles/:id", requireScope("cellar:read"), async (req, res) => res.json(await service.get(principal(res).owner, uuid.parse(req.params.id))));
  app.get("/v1/sync-status", requireScope("cellar:read"), async (_req, res) => res.json(await service.status(principal(res).owner)));
  app.post("/v1/ack", requireScope("cellar:write"), async (req, res) => {
    const { cursor: value } = z.object({ cursor }).strict().parse(req.body);
    await service.acknowledge(principal(res).owner, value);
    res.json({ ok: true });
  });
  app.post("/mcp", async (req, res) => {
    const server = createMCP(service, principal(res), config.resource);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on("close", () => { void transport.close(); void server.close(); });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  });
  app.all("/mcp", (_req, res) => { res.set("Allow", "POST").sendStatus(405); });
  const handleError: ErrorRequestHandler = (error, _req, res, _next) => {
    const code = error instanceof ServiceError ? error.code : error instanceof z.ZodError || error instanceof SyntaxError ? "VALIDATION_ERROR" : "INTERNAL_ERROR";
    const status = error instanceof ServiceError ? error.status : code === "VALIDATION_ERROR" ? 400 : 500;
    if (status === 401 || status === 403)
      res.set("WWW-Authenticate", `Bearer resource_metadata="${metadataURL}", error="${status === 403 ? "insufficient_scope" : "invalid_token"}", error_description="Cork authorization required"`);
    res.status(status).json({ code, ...(error instanceof ServiceError && error.current ? { current: error.current } : {}) });
  };
  app.use(handleError);
  return app;
}
