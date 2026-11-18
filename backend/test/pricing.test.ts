import { describe, expect, it } from "vitest";
import { AVERAGE_RECAP_MICRO, PLANS, nextPeriodStart, recapsRemaining } from "../src/plans";
import { costMicro, effectiveMaxTokens, inputOnlyMicro, inputTokensUpperBound, rateFor, reserveMicro, supportsEffort } from "../src/pricing";

describe("pricing", () => {
  it("prices a call in whole micro-dollars", () => {
    // 1,000 input at $2/M plus 500 output at $10/M.
    expect(costMicro("claude-sonnet-5-5", 1000, 500)).toBe(7_000);
    expect(costMicro("claude-haiku-4-5-20251001", 1000, 500)).toBe(3_500);
  });

  it("resolves dated ids to their family and prefers the longest prefix", () => {
    expect(rateFor("claude-haiku-4-5-20251001")).toEqual({ input: 1, output: 5 });
    expect(rateFor("claude-opus-5-5")).toEqual({ input: 4, output: 20 });
    expect(rateFor("claude-opus-5")).toEqual({ input: 5, output: 25 });
  });

  it("has no price for an unknown model, so it cannot be used by accident", () => {
    expect(rateFor("claude-haiku-5-5")).toBeNull();
    expect(() => costMicro("claude-haiku-5-5", 1, 1)).toThrow();
    expect(() => reserveMicro("mystery", 1, 1)).toThrow();
  });

  it("rounds up so spend is never understated", () => {
    expect(costMicro("claude-haiku-4-5", 1, 1)).toBe(6);
    expect(costMicro("claude-sonnet-5-5", 0, 0)).toBe(0);
  });

  it("gives thinking models headroom, but never above the ceiling", () => {
    expect(effectiveMaxTokens("claude-sonnet-5-5", 4_096, 32_000)).toBe(16_000);
    expect(effectiveMaxTokens("claude-sonnet-5-5", 20_000, 32_000)).toBe(20_000);
    expect(effectiveMaxTokens("claude-sonnet-5-5", 4_096, 8_000)).toBe(8_000);
    expect(effectiveMaxTokens("claude-haiku-4-5", 4_096, 16_000)).toBe(4_096);
  });

  it("sends effort only to models that accept it", () => {
    expect(supportsEffort("claude-sonnet-5-5")).toBe(true);
    expect(supportsEffort("claude-haiku-4-5-20251001")).toBe(false);
  });

  it("bounds input tokens by bytes, since a token is never shorter than one byte", () => {
    expect(inputTokensUpperBound(0)).toBe(1_000);
    expect(inputTokensUpperBound(180_000)).toBe(181_000);
    // Dense non-English text is the worst case: 3 bytes per character at about one token each.
    expect(inputTokensUpperBound(3 * 60_000)).toBeGreaterThanOrEqual(60_000);
  });

  it("reserves the input bound plus all of max_tokens, and the input alone for a dropped connection", () => {
    expect(reserveMicro("claude-sonnet-5-5", 10_000, 16_000)).toBe(11_000 * 2 + 16_000 * 10);
    expect(inputOnlyMicro("claude-sonnet-5-5", 10_000)).toBe(11_000 * 2);
    expect(() => inputOnlyMicro("mystery", 1)).toThrow();
  });

  it("reserves more than a typical call actually costs", () => {
    const reserve = reserveMicro("claude-sonnet-5-5", 20_000, 16_000);
    expect(reserve).toBeGreaterThan(costMicro("claude-sonnet-5-5", 8_000, 6_000));
    expect(reserve).toBeGreaterThan(AVERAGE_RECAP_MICRO);
  });
});

describe("plans", () => {
  it("shows the smaller of what the count and the budget allow", () => {
    expect(recapsRemaining(PLANS.free, 0, 0)).toBe(3);
    expect(recapsRemaining(PLANS.free, 3, 100_000)).toBe(0);
    expect(recapsRemaining(PLANS.plus, 0, 0)).toBe(Math.floor(PLANS.plus.budgetMicro / AVERAGE_RECAP_MICRO));
    expect(recapsRemaining(PLANS.plus, 10, PLANS.plus.budgetMicro)).toBe(0);
    expect(recapsRemaining(PLANS.plus, 0, PLANS.plus.budgetMicro * 2)).toBe(0);
  });

  it("resets on the first of next month, UTC", () => {
    expect(nextPeriodStart(Date.UTC(2026, 10, 18, 12))).toBe("2026-12-01T00:00:00.000Z");
    expect(nextPeriodStart(Date.UTC(2026, 11, 31, 23, 59))).toBe("2027-01-01T00:00:00.000Z");
  });

  it("keeps the Plus budget under the net price with margin", () => {
    const net = 6.99 * 0.85; // after Apple's 15% Small Business rate
    expect(PLANS.plus.budgetMicro / 1_000_000).toBeLessThan(net * 0.7);
  });
});
