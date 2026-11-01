import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { CellarService } from "../src/db.js";
import { bottleSchema, ServiceError } from "../src/contracts.js";
import { bottle, database } from "./helpers.js";

test("retry returns original result before stale-version validation; changed content is rejected", async t => {
  const db = await database(); t.after(() => db.close());
  const service = new CellarService(db), owner = randomUUID(), value = bottle();
  const operation = { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "create", bottle: value } };
  const first = await service.perform(owner, operation);
  assert.deepEqual(await service.perform(owner, operation), first);
  await assert.rejects(() => service.perform(owner, { ...operation, action: { kind: "create", bottle: { ...value, name: "Changed" } } }), (e: ServiceError) => e.code === "OPERATION_ID_REUSED");
  assert.equal((await service.changes(owner, 0)).changes.length, 1);
});

test("owner and version checks prevent cross-account access and lost updates", async t => {
  const db = await database(); t.after(() => db.close());
  const service = new CellarService(db), owner = randomUUID(), value = bottle();
  const created = await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "create", bottle: value } });
  await assert.rejects(() => service.get(randomUUID(), value.id), (e: ServiceError) => e.code === "NOT_FOUND");
  const patch = { bottleID: value.id, baseVersion: created.version, action: { kind: "patch", patch: { note: "Berries" } } };
  await service.perform(owner, { ...patch, operationID: randomUUID() });
  await assert.rejects(() => service.perform(owner, { ...patch, operationID: randomUUID() }), (e: ServiceError) => e.code === "VERSION_CONFLICT");
  const saved = await service.get(owner, value.id);
  assert.equal(saved.bottle?.storageLocation, "Rack A");
  assert.equal(saved.bottle?.note, "Berries");
});

test("fixed paging boundary excludes later writes without dropping them", async t => {
  const db = await database(); t.after(() => db.close());
  const service = new CellarService(db), owner = randomUUID();
  const create = () => { const b = bottle(); return service.perform(owner, { operationID: randomUUID(), bottleID: b.id, baseVersion: 0, action: { kind: "create", bottle: b } }); };
  await Promise.all([create(), create()]);
  const page = await service.changes(owner, 0, undefined, 1);
  await create();
  const second = await service.changes(owner, page.nextCursor, page.until, 1);
  assert.equal(second.hasMore, false);
  assert.equal(second.nextCursor, 2);
  assert.equal((await service.changes(owner, second.nextCursor)).changes[0]?.cursor, 3);
});

test("state changes keep the original offline event time; tombstones prevent resurrection", async t => {
  const db = await database(); t.after(() => db.close());
  const service = new CellarService(db), owner = randomUUID(), value = bottle();
  const created = await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "create", bottle: value } });
  const occurredAt = "2026-10-31T15:00:00Z";
  const opened = await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: created.version, action: { kind: "state", state: "opened", eventID: randomUUID(), occurredAt } });
  assert.equal(opened.bottle?.openedAt, occurredAt);
  const deleted = await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: opened.version, action: { kind: "delete" } });
  assert.equal(deleted.bottle, null);
  await assert.rejects(() => service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "import", bottle: value } }), (e: ServiceError) => e.code === "VERSION_CONFLICT");
});

test("operation result failure rolls back data, cursor and history together", async t => {
  const db = await database(); t.after(() => db.close());
  const broken = { ...db, async connect() {
    const connection = await db.connect();
    return { ...connection, async query(sql: string, values?: unknown[]) {
      if (sql.startsWith("INSERT INTO operation_results")) throw new Error("injected failure");
      return connection.query(sql, values);
    } };
  } };
  const owner = randomUUID(), value = bottle();
  await assert.rejects(() => new CellarService(broken).perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "create", bottle: value } }));
  assert.equal((await new CellarService(db).changes(owner, 0)).until, 0);
  assert.deepEqual(await new CellarService(db).list(owner), []);
});

test("private local fields are never accepted by the cloud contract", () => {
  assert.equal(bottleSchema.safeParse({ ...bottle(), purchasePrice: 1000 }).success, false);
  assert.equal(bottleSchema.safeParse({ ...bottle(), ocrRawText: "Private" }).success, false);
});

test("iOS aggregate replacement is versioned and cannot change identity", async t => {
  const db = await database(); t.after(() => db.close());
  const service = new CellarService(db), owner = randomUUID(), value = bottle();
  const created = await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "create", bottle: value } });
  const changed = { ...value, note: "Offline edit" };
  const replaced = await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: created.version, action: { kind: "replace", bottle: changed } });
  assert.equal(replaced.bottle?.note, "Offline edit");
  await assert.rejects(() => service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: replaced.version, action: { kind: "replace", bottle: { ...changed, wineID: randomUUID() } } }), (e: ServiceError) => e.code === "VALIDATION_ERROR");
});

test("a pending transaction cannot publish a later cursor", { skip: !process.env.TEST_DATABASE_URL }, async t => {
  const db = await database(); t.after(() => db.close());
  const service = new CellarService(db), owner = randomUUID(), value = bottle();
  await service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 0, action: { kind: "create", bottle: value } });
  const connection = await db.connect();
  await connection.query("BEGIN");
  await connection.query("SELECT revision FROM cellars WHERE owner=$1 FOR UPDATE", [owner]);
  const pending = service.perform(owner, { operationID: randomUUID(), bottleID: value.id, baseVersion: 1, action: { kind: "patch", patch: { note: "Later" } } });
  try { assert.equal((await service.changes(owner, 0)).until, 1); }
  finally { await connection.query("COMMIT"); connection.release(); }
  assert.equal((await pending).cursor, 2);
});
