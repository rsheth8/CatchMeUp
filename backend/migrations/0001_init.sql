-- Identity. The provider subject is stored only as a SHA-256 of "provider:sub",
-- so a database leak holds no usable Apple or Google identifier. Deleting an
-- account clears the email and marks it deleted but keeps the row, so signing
-- in again cannot reset a free quota (see README, "Account deletion").
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  provider      TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  identity_hash TEXT NOT NULL,
  email         TEXT,
  created_at    INTEGER NOT NULL,
  deleted_at    INTEGER,
  UNIQUE (provider, identity_hash)
);

-- Long-lived refresh tokens. Only a hash is stored; the token itself exists on
-- the phone. They are not rotated, so a retried request after a network drop
-- can never lock someone out. Expiry slides forward each time one is used.
CREATE TABLE refresh_tokens (
  token_hash   TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users (id),
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER,
  expires_at   INTEGER NOT NULL,
  revoked_at   INTEGER
);
CREATE INDEX idx_refresh_user ON refresh_tokens (user_id);

-- Written by App Store Server Notifications (phase 4). A user is on "plus"
-- while expires_at is in the future.
CREATE TABLE subscriptions (
  user_id                 TEXT PRIMARY KEY REFERENCES users (id),
  product_id              TEXT NOT NULL,
  original_transaction_id TEXT UNIQUE,
  status                  TEXT NOT NULL,
  expires_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL
);

-- One row per model call. A row is inserted as 'pending' with a worst-case
-- reservation, in the same statement that checks every limit, then settled with
-- the real cost. Usage is always summed from here, never kept in counters, so
-- it cannot drift. A pending row older than the pending TTL stops counting,
-- which frees the reservation if a request dies halfway.
CREATE TABLE ledger (
  id             TEXT PRIMARY KEY,
  user_id        TEXT NOT NULL REFERENCES users (id),
  period         TEXT NOT NULL,   -- UTC month, e.g. 2026-11
  day            TEXT NOT NULL,   -- UTC day, e.g. 2026-11-18
  task           TEXT NOT NULL,
  model          TEXT NOT NULL,
  status         TEXT NOT NULL CHECK (status IN ('pending', 'settled', 'failed')),
  reserved_micro INTEGER NOT NULL,
  cost_micro     INTEGER NOT NULL DEFAULT 0,
  input_tokens   INTEGER NOT NULL DEFAULT 0,
  output_tokens  INTEGER NOT NULL DEFAULT 0,
  created_at     INTEGER NOT NULL,
  settled_at     INTEGER
);
CREATE INDEX idx_ledger_user_period ON ledger (user_id, period, status);
CREATE INDEX idx_ledger_day ON ledger (day, status);
CREATE INDEX idx_ledger_user_time ON ledger (user_id, created_at);
