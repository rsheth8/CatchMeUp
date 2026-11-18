/**
 * List prices in dollars per million tokens. Because $1 per million tokens is
 * exactly 1 micro-dollar per token, costs below are integer micro-dollars.
 *
 * A model with no entry here is refused rather than guessed at: pricing a call
 * too low would quietly break the spend limits. Add a model only after reading
 * its price on Anthropic's pricing page. These are the rates the benchmark in
 * ios/Bench used, and they are an input to the limits, not a billing source of
 * truth. The Anthropic Console spend limit is the final backstop.
 */
export interface Rate {
  input: number;
  output: number;
}

// Longest prefix wins, so a dated id such as claude-haiku-4-5-20251001 resolves.
const TABLE: Array<[string, Rate]> = [
  ["claude-opus-5-5", { input: 4, output: 20 }],
  ["claude-opus-5", { input: 5, output: 25 }],
  ["claude-sonnet-5-5", { input: 2, output: 10 }],
  ["claude-sonnet-5", { input: 2, output: 10 }],
  ["claude-sonnet-4-6", { input: 3, output: 15 }],
  ["claude-haiku-4-5", { input: 1, output: 5 }],
].sort((a, b) => (b[0] as string).length - (a[0] as string).length) as Array<[string, Rate]>;

export function rateFor(model: string): Rate | null {
  return TABLE.find(([prefix]) => model.startsWith(prefix))?.[1] ?? null;
}

/** Actual cost of a call, rounded up so spend is never understated. */
export function costMicro(model: string, inputTokens: number, outputTokens: number): number {
  const rate = rateFor(model);
  if (!rate) throw new Error(`No price for model ${model}`);
  return Math.ceil(inputTokens * rate.input + outputTokens * rate.output);
}

/** Models that accept output_config.effort. Haiku 4.5 does not. */
export function supportsEffort(model: string): boolean {
  return ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable", "claude-mythos"].some((p) =>
    model.startsWith(p),
  );
}

/**
 * Models that think by default, where thinking tokens share max_tokens with
 * the answer and a small cap cuts a long recap short.
 */
export const THINKING_HEADROOM = 16_000;
export function thinksByDefault(model: string): boolean {
  return supportsEffort(model);
}

export function effectiveMaxTokens(model: string, requested: number, ceiling: number): number {
  const wanted = thinksByDefault(model) ? Math.max(requested, THINKING_HEADROOM) : requested;
  return Math.min(wanted, ceiling);
}

/**
 * Worst case for one call, held against the budgets until the real cost is
 * known. Input is estimated pessimistically at 2.5 characters per token
 * (English is nearer 4), and output is assumed to use all of max_tokens.
 */
export function reserveMicro(model: string, inputChars: number, maxTokens: number): number {
  const rate = rateFor(model);
  if (!rate) throw new Error(`No price for model ${model}`);
  const inputTokens = Math.ceil(inputChars / 2.5) + 1_000;
  return Math.ceil(inputTokens * rate.input + maxTokens * rate.output);
}
