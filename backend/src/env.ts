/** Bindings, variables and secrets. See wrangler.toml and .dev.vars.example. */
export interface Env {
  DB: D1Database;

  // Secrets
  ANTHROPIC_API_KEY: string;
  SESSION_SECRET: string;

  // Sign-in providers
  APPLE_AUDIENCE: string;
  APPLE_ISSUER: string;
  APPLE_JWKS_URL: string;
  GOOGLE_AUDIENCE: string;
  GOOGLE_ISSUERS: string;
  GOOGLE_JWKS_URL: string;

  // Model
  ANTHROPIC_BASE_URL: string;
  /** Model for each plan. Each needs a price in src/pricing.ts. */
  RECAP_MODEL_FREE: string;
  RECAP_MODEL_PLUS: string;
  RECAP_EFFORT?: string;

  // Hard ceilings
  GLOBAL_DAILY_BUDGET_USD: string;
  MAX_INPUT_BYTES: string;
  MAX_OUTPUT_TOKENS: string;
  RATE_LIMIT_PER_MINUTE: string;
}

/**
 * Things the handler needs from the outside world, so tests can replace the
 * network, the clock and sleeping without touching module state.
 */
export interface Deps {
  fetch: typeof fetch;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
}

export const defaultDeps: Deps = {
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
};
