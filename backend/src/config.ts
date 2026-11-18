import type { Env } from "./env";
import { ApiError } from "./http";
import { rateFor } from "./pricing";

export interface Config {
  apiKey: string;
  baseUrl: string;
  model: string;
  effort: string | null;
  globalDailyBudgetMicro: number;
  maxInputChars: number;
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
  if (!env.RECAP_MODEL || !rateFor(env.RECAP_MODEL)) {
    throw new ApiError(500, "misconfigured", "The service is not configured correctly.", { setting: "RECAP_MODEL" });
  }
  return {
    apiKey: env.ANTHROPIC_API_KEY,
    baseUrl: (env.ANTHROPIC_BASE_URL || "https://api.anthropic.com").replace(/\/+$/, ""),
    model: env.RECAP_MODEL,
    effort: env.RECAP_EFFORT || null,
    globalDailyBudgetMicro: Math.round(positive("GLOBAL_DAILY_BUDGET_USD", env.GLOBAL_DAILY_BUDGET_USD) * 1_000_000),
    maxInputChars: positive("MAX_INPUT_CHARS", env.MAX_INPUT_CHARS),
    maxOutputTokens: positive("MAX_OUTPUT_TOKENS", env.MAX_OUTPUT_TOKENS),
    rateLimitPerMinute: positive("RATE_LIMIT_PER_MINUTE", env.RATE_LIMIT_PER_MINUTE),
  };
}
