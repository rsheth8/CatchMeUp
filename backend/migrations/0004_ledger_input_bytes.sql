-- The size of each call's prompt, so a recording's cumulative input can be
-- capped. Without it a reused job id would be worth an unlimited amount of
-- transcript, because the id is chosen by the client.
ALTER TABLE ledger ADD COLUMN input_bytes INTEGER NOT NULL DEFAULT 0;
