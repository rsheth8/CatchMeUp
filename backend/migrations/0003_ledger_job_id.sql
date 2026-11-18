-- A "recap" for quota purposes is one recording, not one model call. The app
-- splits a long recording into several windows and may make a follow-up call for
-- meeting insights, and every one of those carries the same job id (the
-- recording's id). Calls with no job id (questions, answers, grading) use
-- dollars from the budget but do not use up a recap.
ALTER TABLE ledger ADD COLUMN job_id TEXT;
CREATE INDEX idx_ledger_user_job ON ledger (user_id, period, job_id);
