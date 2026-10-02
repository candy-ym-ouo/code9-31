-- 电影取景灵感库 · 初始表结构（对应项目文档第 8 章）
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS "user" (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  display_name  TEXT NOT NULL,
  timezone      TEXT NOT NULL DEFAULT 'Asia/Shanghai',
  home_lat      REAL,
  home_lng      REAL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS library (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL,
  owner_id           TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  default_fuzz_level TEXT NOT NULL DEFAULT 'g500',
  tz                 TEXT NOT NULL DEFAULT 'Asia/Shanghai',
  created_at         TEXT NOT NULL,
  updated_at         TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS library_member (
  id         TEXT PRIMARY KEY,
  library_id TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  user_id    TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  role       TEXT NOT NULL CHECK (role IN ('owner','member')),
  created_at TEXT NOT NULL,
  UNIQUE (library_id, user_id)
);

CREATE TABLE IF NOT EXISTS place (
  id            TEXT PRIMARY KEY,
  library_id    TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  city          TEXT,
  district      TEXT,
  address_text  TEXT,
  category      TEXT,
  centroid_lat  REAL,
  centroid_lng  REAL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_place_library ON place(library_id);

CREATE TABLE IF NOT EXISTS spot (
  id             TEXT PRIMARY KEY,
  library_id     TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  place_id       TEXT NOT NULL REFERENCES place(id) ON DELETE CASCADE,
  -- 精确坐标：仅存在于本表，序列化层是唯一出口（文档 13.3）
  lat            REAL NOT NULL,
  lng            REAL NOT NULL,
  camera_bearing REAL NOT NULL DEFAULT 0,
  elevation_m    REAL,
  access_note    TEXT,
  best_time_note TEXT,
  visibility     TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private','fuzzy_shared')),
  tz             TEXT NOT NULL DEFAULT 'Asia/Shanghai',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_spot_library ON spot(library_id);
CREATE INDEX IF NOT EXISTS idx_spot_place ON spot(place_id);

CREATE TABLE IF NOT EXISTS place_fuzz_cache (
  id          TEXT PRIMARY KEY,
  library_id  TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  spot_id     TEXT NOT NULL REFERENCES spot(id) ON DELETE CASCADE,
  fuzz_level  TEXT NOT NULL,
  fuzz_lat    REAL,
  fuzz_lng    REAL,
  fuzz_label  TEXT NOT NULL,
  geohash     TEXT NOT NULL,
  computed_at TEXT NOT NULL,
  UNIQUE (spot_id, fuzz_level)
);

CREATE TABLE IF NOT EXISTS inspiration (
  id              TEXT PRIMARY KEY,
  library_id      TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  title           TEXT NOT NULL,
  note            TEXT,
  status          TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','tagging','timing_missing','ready','scheduled','shot','archived','dropped')),
  season_tags     TEXT NOT NULL DEFAULT '[]',
  spot_id         TEXT REFERENCES spot(id) ON DELETE SET NULL,
  hit_count       INTEGER NOT NULL DEFAULT 0,
  partial_count   INTEGER NOT NULL DEFAULT 0,
  miss_count      INTEGER NOT NULL DEFAULT 0,
  hit_rate        REAL NOT NULL DEFAULT 0,
  archived_reason TEXT,
  deleted_at      TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_insp_library_status ON inspiration(library_id, status);
CREATE INDEX IF NOT EXISTS idx_insp_library_updated ON inspiration(library_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_insp_spot ON inspiration(spot_id);

CREATE TABLE IF NOT EXISTS asset (
  id              TEXT PRIMARY KEY,
  library_id      TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  inspiration_id  TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  role            TEXT NOT NULL DEFAULT 'reference' CHECK (role IN ('reference','detail','panorama','result')),
  file_path       TEXT NOT NULL,
  thumb_path      TEXT,
  mime            TEXT,
  width           INTEGER NOT NULL DEFAULT 0,
  height          INTEGER NOT NULL DEFAULT 0,
  bytes           INTEGER NOT NULL DEFAULT 0,
  sha256          TEXT,
  shot_at         TEXT,
  camera_model    TEXT,
  lens            TEXT,
  iso             INTEGER,
  aperture        TEXT,
  shutter         TEXT,
  has_gps_exif    INTEGER NOT NULL DEFAULT 0,
  palette         TEXT NOT NULL DEFAULT '[]',
  sun_elevation   REAL,
  sun_azimuth     REAL,
  weather_snapshot TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_asset_insp ON asset(inspiration_id, role);
CREATE INDEX IF NOT EXISTS idx_asset_sha ON asset(library_id, sha256);

CREATE TABLE IF NOT EXISTS tag (
  id          TEXT PRIMARY KEY,
  library_id  TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  domain      TEXT NOT NULL CHECK (domain IN ('light','scene','color','composition')),
  parent_id   TEXT REFERENCES tag(id) ON DELETE SET NULL,
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  is_builtin  INTEGER NOT NULL DEFAULT 0,
  disabled    INTEGER NOT NULL DEFAULT 0,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  usage_count INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  UNIQUE (library_id, domain, slug)
);
CREATE INDEX IF NOT EXISTS idx_tag_library_domain ON tag(library_id, domain);

CREATE TABLE IF NOT EXISTS inspiration_tag (
  inspiration_id TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  tag_id         TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
  source         TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','bulk','album_gap','suggested')),
  confidence     REAL,
  created_at     TEXT NOT NULL,
  PRIMARY KEY (inspiration_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_insp_tag_tag ON inspiration_tag(tag_id);

CREATE TABLE IF NOT EXISTS composition_note (
  id         TEXT PRIMARY KEY,
  library_id TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  asset_id   TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  geometry   TEXT NOT NULL,
  label      TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_annotation_asset ON composition_note(asset_id);

CREATE TABLE IF NOT EXISTS timing (
  id                   TEXT PRIMARY KEY,
  library_id           TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  inspiration_id       TEXT NOT NULL UNIQUE REFERENCES inspiration(id) ON DELETE CASCADE,
  time_anchor          TEXT NOT NULL,
  anchor_offset_min    INTEGER NOT NULL DEFAULT 0,
  elevation_range      TEXT NOT NULL DEFAULT '[-90,90]',
  azimuth_range        TEXT,
  azimuth_tolerance    REAL NOT NULL DEFAULT 15,
  window_tolerance_min INTEGER NOT NULL DEFAULT 12,
  weather_profile      TEXT NOT NULL DEFAULT '{}',
  season_window        TEXT,
  repeat_rule          TEXT,
  notes                TEXT,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS repro_window (
  id                TEXT PRIMARY KEY,
  library_id        TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  inspiration_id    TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  date              TEXT NOT NULL,
  start_at          TEXT NOT NULL,
  end_at            TEXT NOT NULL,
  anchor_at         TEXT NOT NULL,
  sun_elevation     REAL,
  sun_azimuth       REAL,
  verdict           TEXT NOT NULL CHECK (verdict IN ('good','marginal','bad')),
  reasons           TEXT NOT NULL DEFAULT '[]',
  forecast_snapshot TEXT,
  weather_degraded  INTEGER NOT NULL DEFAULT 0,
  stale             INTEGER NOT NULL DEFAULT 0,
  computed_at       TEXT NOT NULL,
  UNIQUE (inspiration_id, date, start_at)
);
CREATE INDEX IF NOT EXISTS idx_window_date ON repro_window(date, verdict);
CREATE INDEX IF NOT EXISTS idx_window_insp ON repro_window(inspiration_id, date);

CREATE TABLE IF NOT EXISTS reminder (
  id             TEXT PRIMARY KEY,
  library_id     TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  user_id        TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  subject_type   TEXT NOT NULL,
  subject_id     TEXT NOT NULL,
  rule_code      TEXT,
  occurrence_key TEXT NOT NULL,
  title          TEXT NOT NULL,
  body           TEXT,
  action_kind    TEXT NOT NULL DEFAULT 'none',
  action_payload TEXT,
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','notified','done','snoozed','dismissed','expired')),
  due_at         TEXT NOT NULL,
  expire_at      TEXT,
  snooze_until   TEXT,
  dismiss_reason TEXT,
  notified_at    TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  -- 注意：唯一键不含 rule_code（事件驱动型提醒 rule_code 为空，SQLite 唯一索引允许多个 NULL）
  UNIQUE (subject_type, subject_id, occurrence_key)
);
CREATE INDEX IF NOT EXISTS idx_reminder_status_due ON reminder(status, due_at);
CREATE INDEX IF NOT EXISTS idx_reminder_library ON reminder(library_id, status);

CREATE TABLE IF NOT EXISTS shoot_plan (
  id             TEXT PRIMARY KEY,
  library_id     TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  inspiration_id TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  window_id      TEXT REFERENCES repro_window(id) ON DELETE SET NULL,
  planned_at     TEXT NOT NULL,
  leave_at       TEXT,
  commute_min    INTEGER NOT NULL DEFAULT 30,
  companions     TEXT,
  gear_note      TEXT,
  window_verdict_at_plan TEXT,
  status         TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','cancelled','done')),
  cancel_reason  TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_plan_library ON shoot_plan(library_id, status, planned_at);

CREATE TABLE IF NOT EXISTS shoot_result (
  id              TEXT PRIMARY KEY,
  library_id      TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  plan_id         TEXT NOT NULL UNIQUE REFERENCES shoot_plan(id) ON DELETE CASCADE,
  inspiration_id  TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  hit_level       TEXT NOT NULL CHECK (hit_level IN ('hit','partial','miss')),
  miss_reasons    TEXT NOT NULL DEFAULT '[]',
  actual_shot_at  TEXT,
  actual_weather  TEXT,
  note            TEXT,
  filled_at       TEXT NOT NULL,
  created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS calibration_log (
  id             TEXT PRIMARY KEY,
  library_id     TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  inspiration_id TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  field          TEXT NOT NULL,
  before_value   TEXT,
  after_value    TEXT,
  reason         TEXT NOT NULL,
  triggered_by   TEXT,
  undone_at      TEXT,
  created_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_calibration_insp ON calibration_log(inspiration_id, created_at DESC);

CREATE TABLE IF NOT EXISTS album (
  id             TEXT PRIMARY KEY,
  library_id     TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  title          TEXT NOT NULL,
  theme_note     TEXT,
  status         TEXT NOT NULL DEFAULT 'planning'
                 CHECK (status IN ('planning','collecting','ready','published','archived')),
  rules          TEXT NOT NULL DEFAULT '{}',
  cover_asset_id TEXT REFERENCES asset(id) ON DELETE SET NULL,
  published_at   TEXT,
  deleted_at     TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS album_item (
  id             TEXT PRIMARY KEY,
  album_id       TEXT NOT NULL REFERENCES album(id) ON DELETE CASCADE,
  inspiration_id TEXT NOT NULL REFERENCES inspiration(id) ON DELETE CASCADE,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  caption        TEXT,
  added_by       TEXT NOT NULL DEFAULT 'manual' CHECK (added_by IN ('manual','auto')),
  created_at     TEXT NOT NULL,
  UNIQUE (album_id, inspiration_id)
);

CREATE TABLE IF NOT EXISTS album_gap (
  id             TEXT PRIMARY KEY,
  album_id       TEXT NOT NULL REFERENCES album(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL CHECK (kind IN ('tag','anchor','weather','count','result')),
  requirement    TEXT NOT NULL,
  current_count  INTEGER NOT NULL DEFAULT 0,
  required_count INTEGER NOT NULL DEFAULT 1,
  is_required    INTEGER NOT NULL DEFAULT 1,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','filled','waived')),
  waive_reason   TEXT,
  filled_by      TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_gap_album ON album_gap(album_id, status);

CREATE TABLE IF NOT EXISTS album_snapshot (
  id            TEXT PRIMARY KEY,
  album_id      TEXT NOT NULL REFERENCES album(id) ON DELETE CASCADE,
  version       INTEGER NOT NULL,
  payload       TEXT NOT NULL,
  payload_hash  TEXT NOT NULL,
  share_link_id TEXT,
  created_at    TEXT NOT NULL,
  UNIQUE (album_id, version)
);

CREATE TABLE IF NOT EXISTS share_link (
  id            TEXT PRIMARY KEY,
  library_id    TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  scope         TEXT NOT NULL CHECK (scope IN ('album','inspiration')),
  scope_id      TEXT NOT NULL,
  token         TEXT NOT NULL UNIQUE,
  fuzz_level    TEXT NOT NULL DEFAULT 'g500',
  password_hash TEXT,
  expires_at    TEXT NOT NULL,
  revoked_at    TEXT,
  created_by    TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  view_count    INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  -- 安全底线：分享级别不得为精确（文档 13.4）
  CHECK (fuzz_level <> 'exact')
);
CREATE INDEX IF NOT EXISTS idx_share_expires ON share_link(expires_at);

CREATE TABLE IF NOT EXISTS share_access_log (
  id            TEXT PRIMARY KEY,
  share_link_id TEXT NOT NULL REFERENCES share_link(id) ON DELETE CASCADE,
  ip_hash       TEXT,
  user_agent    TEXT,
  path          TEXT,
  allowed       INTEGER NOT NULL DEFAULT 1,
  deny_reason   TEXT,
  at            TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_share_log ON share_access_log(share_link_id, at DESC);

CREATE TABLE IF NOT EXISTS notification_channel (
  id                TEXT PRIMARY KEY,
  library_id        TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  kind              TEXT NOT NULL CHECK (kind IN ('sse','webhook')),
  target            TEXT,
  enabled           INTEGER NOT NULL DEFAULT 1,
  quiet_hours       TEXT NOT NULL DEFAULT '22:00-07:00',
  daily_digest_hour INTEGER NOT NULL DEFAULT 8,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS offline_op (
  id           TEXT PRIMARY KEY,
  library_id   TEXT NOT NULL REFERENCES library(id) ON DELETE CASCADE,
  client_op_id TEXT NOT NULL,
  op_type      TEXT NOT NULL,
  payload      TEXT NOT NULL,
  result       TEXT,
  applied_at   TEXT,
  created_at   TEXT NOT NULL,
  -- 幂等键按库隔离：同一 client_op_id 可在不同库各自补录、各自独立且仅生效一次
  UNIQUE (library_id, client_op_id)
);

CREATE TABLE IF NOT EXISTS weather_cache (
  id          TEXT PRIMARY KEY,
  cache_key   TEXT NOT NULL UNIQUE,
  payload     TEXT NOT NULL,
  fetched_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS climate_cache (
  id          TEXT PRIMARY KEY,
  cache_key   TEXT NOT NULL UNIQUE,
  payload     TEXT NOT NULL,
  fetched_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS job_run (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  started_at  TEXT NOT NULL,
  finished_at TEXT,
  ok          INTEGER,
  message     TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS inspiration_fts USING fts5(
  inspiration_id UNINDEXED,
  title,
  note,
  place,
  tags,
  tokenize = 'unicode61'
);
