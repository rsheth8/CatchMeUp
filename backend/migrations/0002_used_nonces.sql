-- Sign-in nonces are issued statelessly (signed, with an expiry) and made
-- single-use here: a nonce is recorded when a sign-in succeeds, and a second
-- attempt with the same nonce hits the primary key and is refused. Rows are
-- only written for sign-ins the provider has already verified, so unauthenticated
-- callers cannot grow this table.
CREATE TABLE used_nonces (
  hash       TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
CREATE INDEX idx_used_nonces_expiry ON used_nonces (expires_at);
