-- 离线补录的幂等键按资料库隔离；同一 client_op_id 在不同资料库中必须各自执行一次。
-- SQLite 不能直接修改列约束，因此在已存在的数据库中重建本表。
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

INSERT INTO offline_op_new (id, library_id, client_op_id, op_type, payload, result, applied_at, created_at)
SELECT id, library_id, client_op_id, op_type, payload, result, applied_at, created_at
FROM offline_op;

DROP TABLE offline_op;
ALTER TABLE offline_op_new RENAME TO offline_op;
