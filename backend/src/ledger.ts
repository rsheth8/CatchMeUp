import type { Plan } from "./plans";

/**
 * A pending reservation older than this is treated as orphaned: the request
 * died before settling. It stops holding a recap slot or showing as "in
 * flight", but it KEEPS counting against the spend budgets at its reserved
 * worst case. That is deliberate. The provider may have billed the call, and
 * a reservation that quietly expired would let someone start requests and walk
 * away from them for free. If an orphan is ever confirmed harmless in the
 * provider's console, an operator can mark it failed with zero cost (README).
 */
export const PENDING_TTL_MS = 10 * 60 * 1000;

export function periodOf(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 7);
}

export function dayOf(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 10);
}

export type Rejection = "rate_limited" | "quota_exceeded" | "request_in_flight" | "service_busy";

export interface ReserveInput {
  id: string;
  userId: string;
  task: string;
  model: string;
  reserveMicro: number;
  nowMs: number;
  plan: Plan;
  globalDailyBudgetMicro: number;
  rateLimitPerMinute: number;
}

// What a row costs against a budget: its real cost once finished (failed calls
// can still have been billed), or its reservation for as long as it is pending,
// however old. Only the recap COUNT below lets stale pending rows go.
const SPEND = `COALESCE(SUM(CASE
  WHEN status IN ('settled', 'failed') THEN cost_micro
  WHEN status = 'pending' THEN reserved_micro
  ELSE 0 END), 0)`;
const RECAPS = `COUNT(CASE
  WHEN status = 'settled' THEN 1
  WHEN status = 'pending' AND created_at > ?9 THEN 1 END)`;

/**
 * Checks every limit and takes the reservation in a single statement, so two
 * simultaneous requests cannot both squeeze under the same limit. Returns
 * false when any limit would be crossed; `diagnose` says which.
 *
 *   ?1 id  ?2 user  ?3 period  ?4 day  ?5 task  ?6 model  ?7 reserve  ?8 now
 *   ?9 pending cutoff  ?10 user budget  ?11 max recaps  ?12 global budget
 *   ?13 rate window start  ?14 max requests in the window
 */
export async function reserve(db: D1Database, input: ReserveInput): Promise<boolean> {
  const { nowMs } = input;
  const result = await db
    .prepare(
      `INSERT INTO ledger (id, user_id, period, day, task, model, status, reserved_micro, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, ?8
       WHERE (SELECT ${SPEND} FROM ledger WHERE user_id = ?2 AND period = ?3) + ?7 <= ?10
         AND (SELECT ${RECAPS} FROM ledger WHERE user_id = ?2 AND period = ?3) < ?11
         AND (SELECT ${SPEND} FROM ledger WHERE day = ?4) + ?7 <= ?12
         AND (SELECT COUNT(*) FROM ledger WHERE user_id = ?2 AND created_at > ?13) < ?14`,
    )
    .bind(
      input.id,
      input.userId,
      periodOf(nowMs),
      dayOf(nowMs),
      input.task,
      input.model,
      input.reserveMicro,
      nowMs,
      nowMs - PENDING_TTL_MS,
      input.plan.budgetMicro,
      input.plan.recapsPerMonth,
      input.globalDailyBudgetMicro,
      nowMs - 60_000,
      input.rateLimitPerMinute,
    )
    .run();
  return (result.meta.changes ?? 0) === 1;
}

/** Why a reservation was refused, for the error the app shows. */
export async function diagnose(db: D1Database, input: ReserveInput): Promise<Rejection> {
  const { nowMs } = input;
  const cutoff = nowMs - PENDING_TTL_MS;
  const period = periodOf(nowMs);

  const recent = await db
    .prepare("SELECT COUNT(*) AS n FROM ledger WHERE user_id = ?1 AND created_at > ?2")
    .bind(input.userId, nowMs - 60_000)
    .first<{ n: number }>();
  if ((recent?.n ?? 0) >= input.rateLimitPerMinute) return "rate_limited";

  // "spent" includes orphaned reservations (see PENDING_TTL_MS); "pending" is
  // only what is genuinely in flight right now.
  const user = await db
    .prepare(
      `SELECT
         COALESCE(SUM(CASE
           WHEN status IN ('settled','failed') THEN cost_micro
           WHEN status = 'pending' AND created_at <= ?3 THEN reserved_micro
           ELSE 0 END), 0) AS spent,
         COALESCE(SUM(CASE WHEN status = 'pending' AND created_at > ?3 THEN reserved_micro ELSE 0 END), 0) AS pending,
         COUNT(CASE WHEN status = 'settled' THEN 1 END) AS settledCount
       FROM ledger WHERE user_id = ?1 AND period = ?2`,
    )
    .bind(input.userId, period, cutoff)
    .first<{ spent: number; pending: number; settledCount: number }>();
  const spent = user?.spent ?? 0;
  if ((user?.settledCount ?? 0) >= input.plan.recapsPerMonth || spent + input.reserveMicro > input.plan.budgetMicro) {
    return "quota_exceeded";
  }
  if (spent + (user?.pending ?? 0) + input.reserveMicro > input.plan.budgetMicro) return "request_in_flight";

  const global = await db
    .prepare(
      `SELECT COALESCE(SUM(CASE
         WHEN status IN ('settled','failed') THEN cost_micro
         WHEN status = 'pending' AND created_at <= ?2 THEN reserved_micro
         ELSE 0 END), 0) AS spent
       FROM ledger WHERE day = ?1`,
    )
    .bind(dayOf(nowMs), cutoff)
    .first<{ spent: number }>();
  if ((global?.spent ?? 0) + input.reserveMicro > input.globalDailyBudgetMicro) return "service_busy";

  // Under every settled limit, so something else was in flight, or the state
  // moved between the refusal and this look. Retrying is the right answer.
  return "request_in_flight";
}

export async function settle(
  db: D1Database,
  id: string,
  usage: { costMicro: number; inputTokens: number; outputTokens: number },
  nowMs: number,
): Promise<void> {
  await db
    .prepare(
      `UPDATE ledger SET status = 'settled', cost_micro = ?2, input_tokens = ?3, output_tokens = ?4, settled_at = ?5
       WHERE id = ?1 AND status = 'pending'`,
    )
    .bind(id, usage.costMicro, usage.inputTokens, usage.outputTokens, nowMs)
    .run();
}

/** The call produced nothing usable. It does not use up a recap, but any billed tokens still count as spend. */
export async function fail(
  db: D1Database,
  id: string,
  usage: { costMicro: number; inputTokens: number; outputTokens: number },
  nowMs: number,
): Promise<void> {
  await db
    .prepare(
      `UPDATE ledger SET status = 'failed', cost_micro = ?2, input_tokens = ?3, output_tokens = ?4, settled_at = ?5
       WHERE id = ?1 AND status = 'pending'`,
    )
    .bind(id, usage.costMicro, usage.inputTokens, usage.outputTokens, nowMs)
    .run();
}

export interface Usage {
  recaps: number;
  spentMicro: number;
}

/** This month's usage for the quota the app displays: finished recaps, and spend including anything still reserved. */
export async function usageFor(db: D1Database, userId: string, nowMs: number): Promise<Usage> {
  const row = await db
    .prepare(
      `SELECT
         COUNT(CASE WHEN status = 'settled' THEN 1 END) AS recaps,
         COALESCE(SUM(CASE
           WHEN status IN ('settled','failed') THEN cost_micro
           WHEN status = 'pending' THEN reserved_micro
           ELSE 0 END), 0) AS spent
       FROM ledger WHERE user_id = ?1 AND period = ?2`,
    )
    .bind(userId, periodOf(nowMs))
    .first<{ recaps: number; spent: number }>();
  return { recaps: row?.recaps ?? 0, spentMicro: row?.spent ?? 0 };
}
