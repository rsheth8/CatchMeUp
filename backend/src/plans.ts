export type PlanId = "free" | "plus";

export interface Plan {
  id: PlanId;
  /** Hard cap on distinct recordings recapped per UTC calendar month. */
  recapsPerMonth: number;
  /** Hard cap on API spend per month, in micro-dollars. This is the real limit. */
  budgetMicro: number;
  /**
   * Calls that carry no job id (questions, answers, grading) per month. They do
   * not use a recap, but a modified client could label a recap as one, so they
   * are counted and capped too, each also held to the per-request input cap.
   */
  otherCallsPerMonth: number;
}

/**
 * Free is promised as "3 recaps a month", so the count is what users hit; the
 * dollar budget is a safety net behind it, sized so that one largest-possible
 * request still fits on either model (about $0.56 reserved on Sonnet, $0.14 on
 * Haiku 5.5, at 200 KB of text). Normal use is about $0.003 a recap on Haiku
 * 5.5 and $0.04 on Sonnet, far under it. Plus is metered in dollars, because cost
 * varies about 2x with recording length, and the count is a sanity ceiling.
 *
 * Sizing: Plus at $6.99 nets about $5.94 after Apple's 15% (Small Business
 * Program). A $3.70 budget leaves roughly $2.20 of margin at the cap, and a
 * typical student will be well under it.
 */
/**
 * Calls one recording may make in a month. A long lecture is a handful of
 * windows plus retries and a meeting-insights call; this is far above that, and
 * exists so a reused job id cannot become unlimited recaps.
 */
export const MAX_CALLS_PER_JOB = 40;

/**
 * The most prompt text one job id can send in a month. The id is chosen by the
 * client, so this is what stops a reused id from being unlimited recaps: a job
 * is worth about one long recording's worth of text, however its calls are
 * labelled. A 3-hour recording is roughly 170 KB of transcript, sent once for
 * notes, again for any retry, and once more for meeting insights.
 */
export const MAX_JOB_INPUT_BYTES = 1_500_000;

export const PLANS: Record<PlanId, Plan> = {
  free: { id: "free", recapsPerMonth: 3, budgetMicro: 600_000, otherCallsPerMonth: 25 },
  plus: { id: "plus", recapsPerMonth: 200, budgetMicro: 3_700_000, otherCallsPerMonth: 600 },
};

/** Measured mean cost of a recap on the default model (ios/Bench, 9 recordings). */
export const AVERAGE_RECAP_MICRO = 37_000;

/** What the app shows: the smaller of what the count and the budget still allow. */
export function recapsRemaining(plan: Plan, usedCount: number, spentMicro: number): number {
  const byCount = plan.recapsPerMonth - usedCount;
  const byBudget = Math.floor((plan.budgetMicro - spentMicro) / AVERAGE_RECAP_MICRO);
  return Math.max(0, Math.min(byCount, byBudget));
}

/** First instant of next month, UTC, when quotas reset. */
export function nextPeriodStart(nowMs: number): string {
  const d = new Date(nowMs);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)).toISOString();
}
