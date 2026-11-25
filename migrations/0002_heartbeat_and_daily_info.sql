-- Heartbeats are now tiny (node_id + time). Versions/metrics arrive once a day via /api/v1/report.
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  ha_url TEXT,
  token_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_seen TEXT
);
ALTER TABLE nodes ADD COLUMN core_version TEXT;
ALTER TABLE nodes ADD COLUMN supervisor_version TEXT;
ALTER TABLE nodes ADD COLUMN os_version TEXT;
ALTER TABLE nodes ADD COLUMN cpu_percent REAL;
ALTER TABLE nodes ADD COLUMN memory_percent REAL;
ALTER TABLE nodes ADD COLUMN disk_percent REAL;
ALTER TABLE nodes ADD COLUMN info_reported_at TEXT;

CREATE TABLE IF NOT EXISTS beats (
  node_id TEXT NOT NULL,
  received_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS beats_node_time ON beats(node_id, received_at);
