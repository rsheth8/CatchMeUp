import type { Env } from "./env";
import { ApiError } from "./http";
import type { PlanId } from "./plans";
import { rateFor } from "./pricing";

export interface Config {
  apiKey: string;
  baseUrl: string;
  /** The model each plan gets. Both are priced, or the service refuses to start. */
  models: Record<PlanId, string>;
  effort: string | null;
  globalDailyBudgetMicro: number;
  /** Cap on the UTF-8 size of system plus user text, which also bounds the reservation. */
  maxInputBytes: number;
  maxOutputTokens: number;
  rateLimitPerMinute: number;
}

function positive(name: string, raw: string | undefined): number {
  const value = Number(raw);
  if (!raw || !Number.isFinite(value) || value <= 0) {
    throw new ApiError(500, "misconfigured", "The service is not configured correctly.", { setting: name });
  }
  return value;
}

/**
 * Reads and validates settings on each request, failing closed: a missing key,
 * an unpriced model or a non-positive limit stops the request instead of
 * letting it through unmetered.
 */
export function loadConfig(env: Env): Config {
  if (!env.ANTHROPIC_API_KEY) throw new ApiError(500, "misconfigured", "The service is not configured correctly.", { setting: "ANTHROPIC_API_KEY" });
  for (const name of ["RECAP_MODEL_FREE", "RECAP_MODEL_PLUS"] as const) {
    if (!env[name] || !rateFor(env[name])) {
      throw new ApiError(500, "misconfigured", "The service is not configured correctly.", { setting: name });
    }
  }
  return {
    apiKey: env.ANTHROPIC_API_KEY,
    baseUrl: (env.ANTHROPIC_BASE_URL || "https://api.anthropic.com").replace(/\/+$/, ""),
    models: { free: env.RECAP_MODEL_FREE, plus: env.RECAP_MODEL_PLUS },
    effort: env.RECAP_EFFORT || null,
    globalDailyBudgetMicro: Math.round(positive("GLOBAL_DAILY_BUDGET_USD", env.GLOBAL_DAILY_BUDGET_USD) * 1_000_000),
    maxInputBytes: positive("MAX_INPUT_BYTES", env.MAX_INPUT_BYTES),
    maxOutputTokens: positive("MAX_OUTPUT_TOKENS", env.MAX_OUTPUT_TOKENS),
    rateLimitPerMinute: positive("RATE_LIMIT_PER_MINUTE", env.RATE_LIMIT_PER_MINUTE),
  };
}
