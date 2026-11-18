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
  /**
   * Some models (Haiku 5.5) charge more for a request whose prompt is over a
   * threshold, on both input and output, for the whole request.
   */
  long?: { aboveInputTokens: number; input: number; output: number };
}

// Longest prefix wins, so a dated id such as claude-haiku-4-5-20251001 resolves.
const TABLE: Array<[string, Rate]> = [
  ["claude-opus-5-5", { input: 4, output: 20 }],
  ["claude-opus-5", { input: 5, output: 25 }],
  ["claude-sonnet-5-5", { input: 2, output: 10 }],
  ["claude-sonnet-5", { input: 2, output: 10 }],
  ["claude-sonnet-4-6", { input: 3, output: 15 }],
  ["claude-haiku-4-5", { input: 1, output: 5 }],
  // Verified on platform.claude.com/docs/en/about-claude/pricing, 18 Nov 2026.
  ["claude-haiku-5-5", { input: 0.1, output: 0.5, long: { aboveInputTokens: 100_000, input: 0.5, output: 2.5 } }],
].sort((a, b) => (b[0] as string).length - (a[0] as string).length) as Array<[string, Rate]>;

export function rateFor(model: string): Rate | null {
  return TABLE.find(([prefix]) => model.startsWith(prefix))?.[1] ?? null;
}

/** Actual cost of a call, rounded up so spend is never understated. */
export function costMicro(model: string, inputTokens: number, outputTokens: number): number {
  const rate = tierFor(model, inputTokens);
  return Math.ceil(inputTokens * rate.input + outputTokens * rate.output);
}

/** The per-token rates that apply to a request with this many prompt tokens. */
function tierFor(model: string, inputTokens: number): { input: number; output: number } {
  const rate = rateFor(model);
  if (!rate) throw new Error(`No price for model ${model}`);
  return rate.long && inputTokens > rate.long.aboveInputTokens ? rate.long : rate;
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
 * Input tokens are bounded above by the prompt's UTF-8 size in bytes: the
 * tokenizer never needs more than one token per byte, because it can always
 * fall back to raw bytes. Real English text is nearer one token per four
 * bytes, so this over-reserves, which is the safe direction. The 1,000 covers
 * the request's own framing.
 */
export function inputTokensUpperBound(inputBytes: number): number {
  return inputBytes + 1_000;
}

/**
 * Worst case for one call, held against the budgets until the real cost is
 * known: the input upper bound, and output assumed to use all of max_tokens.
 */
export function reserveMicro(model: string, inputBytes: number, maxTokens: number): number {
  const inputTokens = inputTokensUpperBound(inputBytes);
  // Reserved at the tier the upper bound lands in, which is never cheaper than the real one.
  const rate = tierFor(model, inputTokens);
  return Math.ceil(inputTokens * rate.input + maxTokens * rate.output);
}

/** The input side alone, charged when a call fails without a usage report and may still have been read. */
export function inputOnlyMicro(model: string, inputBytes: number): number {
  const inputTokens = inputTokensUpperBound(inputBytes);
  return Math.ceil(inputTokens * tierFor(model, inputTokens).input);
}
