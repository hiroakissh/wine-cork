import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { tokenVerifier, secureURL } from "../src/auth.js";
import { ServiceError } from "../src/contracts.js";
import { createApp } from "../src/http.js";
import { CellarService } from "../src/db.js";
import { database } from "./helpers.js";

test("JWT signature, issuer, audience, expiration and stable subject are enforced", async t => {
  const { privateKey, publicKey } = await generateKeyPair("ES256");
  const jwk = { ...await exportJWK(publicKey), kid: "test", alg: "ES256" };
  const server = createServer((_req, res) => { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify({ keys: [jwk] })); });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise<void>(resolve => server.close(() => resolve())));
  const address = server.address() as { port: number };
  const issuer = "https://auth.cork.example", resource = "https://cork.example/mcp";
  const verify = tokenVerifier({ issuer, resource, jwksURL: new URL(`http://127.0.0.1:${address.port}/jwks`) });
  const sign = (audience = resource, expiration = "1h", iss = issuer) => new SignJWT({ scope: "cellar:read" }).setProtectedHeader({ alg: "ES256", kid: "test" }).setSubject("stable-user").setIssuer(iss).setAudience(audience).setIssuedAt().setExpirationTime(expiration).sign(privateKey);
  const first = await verify(await sign());
  assert.equal((await verify(await sign())).owner, first.owner);
  for (const token of [await sign("wrong"), await sign(resource, "-1h"), await sign(resource, "1h", "https://other.example")])
    await assert.rejects(() => verify(token), (e: ServiceError) => e.code === "AUTH_REQUIRED");
  assert.throws(() => secureURL("http://public.example"));
  assert.throws(() => secureURL("http://localhost:8787"));
  assert.equal(secureURL("http://localhost:8787", true).hostname, "localhost");
});

test("HTTP discovery is public but operations require an authorized scope", async t => {
  const db = await database(); t.after(() => db.close());
  const app = createApp(new CellarService(db), async token => {
    if (token !== "reader") throw new ServiceError("AUTH_REQUIRED", 401);
    return { owner: "test-owner", scopes: new Set(["cellar:read"]) };
  }, { resource: "http://127.0.0.1:8787/mcp", issuer: "https://auth.cork.example" });
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  t.after(() => new Promise<void>(resolve => server.close(() => resolve())));
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  assert.equal((await fetch(`${url}/.well-known/oauth-protected-resource`)).status, 200);
  const unauthenticated = await fetch(`${url}/v1/profile`);
  assert.equal(unauthenticated.status, 401);
  assert.match(unauthenticated.headers.get("www-authenticate")!, /resource_metadata/);
  assert.equal((await fetch(`${url}/v1/profile`, { headers: { authorization: "Bearer reader" } })).status, 200);
  assert.equal((await fetch(`${url}/v1/operations`, { method: "POST", headers: { authorization: "Bearer reader", "content-type": "application/json" }, body: "{}" })).status, 403);
  assert.equal((await fetch(`${url}/health`, { headers: { origin: "https://untrusted.example" } })).status, 403);
});
