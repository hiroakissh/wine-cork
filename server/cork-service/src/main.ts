import { discoverAuth, secureURL, tokenVerifier } from "./auth.js";
import { CellarService, migrate, postgres } from "./db.js";
import { createApp } from "./http.js";

const development = process.env.NODE_ENV === "development";
const publicURL = secureURL(required("CORK_PUBLIC_URL"), development);
if (publicURL.pathname !== "/" || publicURL.search || publicURL.hash) throw new Error("CORK_PUBLIC_URL must be an origin");
const resource = `${publicURL.origin}/mcp`;
const config = await discoverAuth(required("CORK_ISSUER"), resource, development);
const db = postgres(required("DATABASE_URL"));
await migrate(db);
createApp(new CellarService(db), tokenVerifier(config), config).listen(Number(process.env.PORT ?? 8787), "0.0.0.0", () => {
  console.log("Cork service started");
});

function required(key: string) {
  const value = process.env[key];
  if (!value) throw new Error(`Missing ${key}`);
  return value;
}
