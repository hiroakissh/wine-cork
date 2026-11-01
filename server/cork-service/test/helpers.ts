import { PGlite } from "@electric-sql/pglite";
import { randomUUID } from "node:crypto";
import { bottleSchema } from "../src/contracts.js";
import { type Database, migrate, postgres } from "../src/db.js";

export async function database(): Promise<Database> {
  if (process.env.TEST_DATABASE_URL) {
    const db = postgres(process.env.TEST_DATABASE_URL);
    await migrate(db);
    return db;
  }
  const pg = new PGlite();
  let tail = Promise.resolve();
  async function acquire() {
    const previous = tail;
    let release!: () => void;
    tail = new Promise<void>(resolve => { release = resolve; });
    await previous;
    return release;
  }
  const query = async (sql: string, values?: unknown[]) => {
    const result = values ? await pg.query(sql, values) : (await pg.exec(sql)).at(-1)!;
    return { rows: result.rows };
  };
  const db: Database = {
    async query(sql, values) { const release = await acquire(); try { return await query(sql, values); } finally { release(); } },
    async connect() { const release = await acquire(); return { query, release }; },
    close: () => pg.close()
  };
  await migrate(db);
  return db;
}

export function bottle() {
  const now = "2026-11-01T10:00:00Z";
  return bottleSchema.parse({
    id: randomUUID(), wineID: randomUUID(), cellarID: randomUUID(), name: "Château Test", wineType: "red",
    lifecycleState: "owned", remainingPercent: 100, storageLocation: "Rack A", bottleShape: "bordeaux",
    createdAt: now, updatedAt: now, tastings: [], pairings: [], events: []
  });
}
