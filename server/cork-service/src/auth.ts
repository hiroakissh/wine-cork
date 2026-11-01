import { createHash } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { type Principal, ServiceError } from "./contracts.js";

export type AuthConfig = { issuer: string; resource: string; jwksURL: URL };
export type VerifyToken = (token: string) => Promise<Principal>;

export function secureURL(value: string, development = false): URL {
  const url = new URL(value);
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.username || url.password || (url.protocol !== "https:" && !(development && local && url.protocol === "http:")))
    throw new Error("HTTPS is required (HTTP loopback is allowed only in development)");
  return url;
}

export async function discoverAuth(issuer: string, resource: string, development = false): Promise<AuthConfig> {
  secureURL(issuer, development);
  const response = await fetch(`${issuer.replace(/\/$/, "")}/.well-known/openid-configuration`, { signal: AbortSignal.timeout(10000) });
  if (!response.ok) throw new Error("OAuth discovery failed");
  const metadata = await response.json() as Record<string, unknown>;
  if (metadata.issuer !== issuer || typeof metadata.jwks_uri !== "string") throw new Error("Invalid OAuth metadata");
  return { issuer, resource, jwksURL: secureURL(metadata.jwks_uri, development) };
}

export function tokenVerifier(config: AuthConfig): VerifyToken {
  const keys = createRemoteJWKSet(config.jwksURL);
  return async token => {
    try {
      const { payload } = await jwtVerify(token, keys, {
        issuer: config.issuer, audience: config.resource, algorithms: ["RS256", "ES256"],
        requiredClaims: ["sub", "exp", "iat"]
      });
      if (!payload.sub?.trim() || typeof payload.scope !== "string") throw new Error("Missing identity or scopes");
      return {
        owner: createHash("sha256").update(JSON.stringify([config.issuer, payload.sub])).digest("hex"),
        scopes: new Set(payload.scope.split(/\s+/))
      };
    } catch { throw new ServiceError("AUTH_REQUIRED", 401); }
  };
}

export function authorize(principal: Principal, scope: string) {
  if (!principal.scopes.has(scope)) throw new ServiceError("FORBIDDEN", 403);
}
