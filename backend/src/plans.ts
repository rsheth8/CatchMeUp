export type PlanId = "free" | "plus";

export interface Plan {
  id: PlanId;
  /** Hard cap on successful model calls per UTC calendar month. */
  recapsPerMonth: number;
  /** Hard cap on API spend per month, in micro-dollars. This is the real limit. */
  budgetMicro: number;
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
export const PLANS: Record<PlanId, Plan> = {
  free: { id: "free", recapsPerMonth: 3, budgetMicro: 600_000 },
  plus: { id: "plus", recapsPerMonth: 200, budgetMicro: 3_700_000 },
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
