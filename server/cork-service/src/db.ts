import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import pg from "pg";
import { type Bottle, type Change, type Operation, ServiceError, bottleSchema, canonical, operationSchema } from "./contracts.js";

export interface SQL { query(text: string, values?: unknown[]): Promise<{ rows: any[] }>; }
export interface Connection extends SQL { release(): void; }
export interface Database extends SQL { connect(): Promise<Connection>; close(): Promise<void>; }
export function postgres(url: string): Database {
  const pool = new pg.Pool({ connectionString: url });
  return {
    query: (sql, values) => pool.query(sql, values),
    close: () => pool.end(),
    async connect() {
      const client = await pool.connect();
      return { query: (sql, values) => client.query(sql, values), release: () => client.release() };
    }
  };
}
export async function migrate(db: SQL) {
  await db.query(await readFile(new URL("../migrations/001.sql", import.meta.url), "utf8"));
}

export class CellarService {
  constructor(private db: Database) {}

  async perform(owner: string, input: unknown, requestIdentity?: unknown): Promise<Change> {
    const operation = operationSchema.parse(input);
    if ((operation.action.kind === "create" || operation.action.kind === "import") && operation.action.bottle.id !== operation.bottleID)
      throw new ServiceError("VALIDATION_ERROR", 400);
    const hash = createHash("sha256").update(canonical(requestIdentity ?? operation)).digest("hex");
    const client = await this.db.connect();
    try {
      await client.query("BEGIN");
      await client.query("INSERT INTO cellars(owner) VALUES ($1) ON CONFLICT DO NOTHING", [owner]);
      // This transactional counter publishes committed prefixes, unlike a sequence.
      const head = (await client.query("SELECT revision FROM cellars WHERE owner=$1 FOR UPDATE", [owner])).rows[0];
      const cached = (await client.query("SELECT request_hash,result FROM operation_results WHERE owner=$1 AND id=$2", [owner, operation.operationID])).rows[0];
      if (cached) {
        if (cached.request_hash !== hash) throw new ServiceError("OPERATION_ID_REUSED", 409);
        await client.query("COMMIT");
        return cached.result as Change;
      }
      const row = (await client.query("SELECT version,payload FROM bottles WHERE owner=$1 AND id=$2", [owner, operation.bottleID])).rows[0];
      const current: Change | undefined = row ? {
        bottleID: operation.bottleID, version: Number(row.version), bottle: row.payload, cursor: Number(head.revision)
      } : undefined;
      const action = operation.action;
      if (action.kind === "import" && current?.bottle && canonical(action.bottle) === canonical(current.bottle)) {
        await this.cache(client, owner, operation.operationID, hash, current);
        await client.query("COMMIT");
        return current;
      }
      if ((current?.version ?? 0) !== operation.baseVersion)
        throw new ServiceError("VERSION_CONFLICT", 409, current);
      let bottle: Bottle | null;
      if (action.kind === "create" || action.kind === "import") {
        if (row) throw new ServiceError("VERSION_CONFLICT", 409, current);
        bottle = action.bottle;
      } else {
        if (!current?.bottle) throw new ServiceError("NOT_FOUND", 404, current);
        bottle = structuredClone(current.bottle);
        this.apply(bottle, operation);
        if (action.kind === "delete") bottle = null;
        else bottle.updatedAt = new Date().toISOString();
      }
      if (bottle) bottle = bottleSchema.parse(bottle);
      const revision = Number(head.revision) + 1;
      const result: Change = { bottleID: operation.bottleID, version: revision, bottle, cursor: revision };
      await client.query("UPDATE cellars SET revision=$2 WHERE owner=$1", [owner, revision]);
      await client.query("INSERT INTO bottles(owner,id,version,payload) VALUES ($1,$2,$3,$4) ON CONFLICT(owner,id) DO UPDATE SET version=$3,payload=$4", [owner, operation.bottleID, revision, bottle ? JSON.stringify(bottle) : null]);
      await client.query("INSERT INTO changes(owner,revision,bottle_id,payload) VALUES ($1,$2,$3,$4)", [owner, revision, operation.bottleID, bottle ? JSON.stringify(bottle) : null]);
      await this.cache(client, owner, operation.operationID, hash, result);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally { client.release(); }
  }

  private cache(client: SQL, owner: string, id: string, hash: string, result: Change) {
    return client.query("INSERT INTO operation_results(owner,id,request_hash,result) VALUES ($1,$2,$3,$4)", [owner, id, hash, JSON.stringify(result)]);
  }

  private apply(bottle: Bottle, { action }: Operation) {
    if (action.kind === "patch") {
      if (bottle.lifecycleState === "finished" && action.patch.remainingPercent != null && action.patch.remainingPercent !== 0)
        throw new ServiceError("VALIDATION_ERROR", 400);
      Object.assign(bottle, action.patch);
    }
    if (action.kind === "state") {
      if (bottle.lifecycleState === action.state) return;
      const occurredAt = action.occurredAt ?? new Date().toISOString();
      bottle.events.push({ id: action.eventID, fromState: bottle.lifecycleState, toState: action.state, occurredAt, note: null });
      bottle.lifecycleState = action.state;
      if (action.state === "owned") { bottle.openedAt = null; bottle.finishedAt = null; bottle.remainingPercent = 100; }
      if (action.state === "opened") { bottle.openedAt ??= occurredAt; bottle.finishedAt = null; bottle.remainingPercent = Math.max(1, bottle.remainingPercent ?? 100); }
      if (action.state === "finished") { bottle.finishedAt ??= occurredAt; bottle.remainingPercent = 0; }
    }
    if (action.kind === "tasting") {
      const old = bottle.tastings.find(item => item.id === action.tasting.id);
      if (old && canonical(old) !== canonical(action.tasting)) throw new ServiceError("VERSION_CONFLICT", 409);
      if (!old) bottle.tastings.push(action.tasting);
    }
    if (action.kind === "pairing") {
      if (action.pairing.tastingID && !bottle.tastings.some(item => item.id === action.pairing.tastingID))
        throw new ServiceError("VALIDATION_ERROR", 400);
      const old = bottle.pairings.find(item => item.id === action.pairing.id);
      if (old && canonical(old) !== canonical(action.pairing)) throw new ServiceError("VERSION_CONFLICT", 409);
      if (!old) bottle.pairings.push(action.pairing);
    }
  }

  async get(owner: string, id: string): Promise<Change> {
    const row = (await this.db.query("SELECT version,payload FROM bottles WHERE owner=$1 AND id=$2", [owner, id])).rows[0];
    if (!row?.payload) throw new ServiceError("NOT_FOUND", 404);
    return { bottleID: id, version: Number(row.version), bottle: row.payload, cursor: Number(row.version) };
  }

  async list(owner: string) {
    const rows = (await this.db.query("SELECT id,version,payload FROM bottles WHERE owner=$1 AND payload IS NOT NULL ORDER BY id", [owner])).rows;
    return rows.map(row => ({ bottleID: row.id as string, version: Number(row.version), bottle: row.payload as Bottle }));
  }

  async changes(owner: string, after: number, until?: number, limit = 50) {
    const head = (await this.db.query("SELECT revision FROM cellars WHERE owner=$1", [owner])).rows[0];
    const upper = until ?? Number(head?.revision ?? 0);
    if (after < 0 || after > upper || upper > Number(head?.revision ?? 0) || limit < 1 || limit > 100)
      throw new ServiceError("VALIDATION_ERROR", 400);
    const rows = (await this.db.query("SELECT revision,bottle_id,payload FROM changes WHERE owner=$1 AND revision>$2 AND revision<=$3 ORDER BY revision LIMIT $4", [owner, after, upper, limit])).rows;
    const changes: Change[] = rows.map(row => ({ bottleID: row.bottle_id, version: Number(row.revision), cursor: Number(row.revision), bottle: row.payload }));
    const nextCursor = changes.at(-1)?.cursor ?? upper;
    return { changes, nextCursor, until: upper, hasMore: nextCursor < upper };
  }

  async status(owner: string) {
    const row = (await this.db.query("SELECT revision,device_cursor,device_synced_at FROM cellars WHERE owner=$1", [owner])).rows[0];
    return { revision: Number(row?.revision ?? 0), deviceCursor: Number(row?.device_cursor ?? 0), deviceSyncedAt: row?.device_synced_at ?? null };
  }

  async acknowledge(owner: string, cursor: number) {
    await this.db.query("UPDATE cellars SET device_cursor=GREATEST(device_cursor,$2),device_synced_at=NOW() WHERE owner=$1 AND revision>=$2", [owner, cursor]);
  }
}
