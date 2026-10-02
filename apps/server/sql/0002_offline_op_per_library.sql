-- 离线补录幂等键按库隔离：client_op_id 是各客户端（各库）本地生成的操作号，
-- 旧的全局 UNIQUE 会让不同库复用同一操作号时命中彼此的旧结果。
-- SQLite 无法直接修改 UNIQUE 约束，按官方迁移流程重建表（旧库按 client_op_id
-- 本身已无重复行，去重后再迁移以保证安全）。
PRAGMA foreign_keys = OFF;

CREATE TABLE IF NOT EXISTS offline_op_new (
  id           TEXT PRIMARY KEY,
  library_id   TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  client_op_id TEXT NOT NULL,
  op_type      TEXT NOT NULL,
  payload      TEXT NOT NULL,
  result       TEXT,
  applied_at   TEXT,
  created_at   TEXT NOT NULL,
  UNIQUE (library_id, client_op_id)
);

INSERT OR IGNORE INTO offline_op_new (id, library_id, client_op_id, op_type, payload, result, applied_at, created_at)
SELECT id, library_id, client_op_id, op_type, payload, result, applied_at, created_at
FROM offline_op;

DROP TABLE offline_op;
ALTER TABLE offline_op_new RENAME TO offline_op;

PRAGMA foreign_keys = ON;
