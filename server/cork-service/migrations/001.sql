CREATE TABLE IF NOT EXISTS cellars (
  owner text PRIMARY KEY, revision bigint NOT NULL DEFAULT 0,
  device_cursor bigint NOT NULL DEFAULT 0, device_synced_at timestamptz
);
CREATE TABLE IF NOT EXISTS bottles (
  owner text NOT NULL REFERENCES cellars(owner), id uuid NOT NULL,
  version bigint NOT NULL, payload jsonb, PRIMARY KEY (owner, id)
);
CREATE TABLE IF NOT EXISTS changes (
  owner text NOT NULL REFERENCES cellars(owner), revision bigint NOT NULL,
  bottle_id uuid NOT NULL, payload jsonb, PRIMARY KEY (owner, revision)
);
CREATE TABLE IF NOT EXISTS operation_results (
  owner text NOT NULL REFERENCES cellars(owner), id uuid NOT NULL,
  request_hash text NOT NULL, result jsonb NOT NULL, PRIMARY KEY (owner, id)
);
