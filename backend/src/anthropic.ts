import type { Config } from "./config";
import type { Deps } from "./env";
import { supportsEffort } from "./pricing";

export interface ModelReply {
  text: string;
  inputTokens: number;
  outputTokens: number;
  stopReason: string | null;
}

/**
 * The model call failed. `inputTokens` and `outputTokens` hold whatever the
 * provider reported, so a response that was billed but unusable (cut off, or
 * declined) is still charged to the budgets.
 */
export class UpstreamFailure extends Error {
  constructor(
    readonly kind: "refused" | "truncated" | "busy" | "http" | "network" | "timeout" | "bad_response",
    message: string,
    readonly status = 0,
    readonly inputTokens = 0,
    readonly outputTokens = 0,
  ) {
    super(message);
  }
}

// Only retried when the provider itself answered with one of these, meaning it
// reports that it did not process the request.
const RETRYABLE = new Set([408, 409, 429, 500, 502, 503, 504, 529]);
const ATTEMPTS = 3;

/**
 * One Messages API call. Sends no sampling parameters, since current models
 * reject non-default ones; `effort` goes only to models that accept it.
 * The key is sent as a header and is never logged or returned.
 */
export async function callModel(
  deps: Deps,
  cfg: Config,
  input: { system: string; user: string; maxTokens: number },
): Promise<ModelReply> {
  const body: Record<string, unknown> = {
    model: cfg.model,
    max_tokens: input.maxTokens,
    system: input.system,
    messages: [{ role: "user", content: input.user }],
  };
  if (cfg.effort && supportsEffort(cfg.model)) body.output_config = { effort: cfg.effort };
  const payload = JSON.stringify(body);

  let lastStatus = 0;
  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    let response: Response;
    try {
      response = await deps.fetch(`${cfg.baseUrl}/v1/messages`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": cfg.apiKey,
          "anthropic-version": "2023-06-01",
        },
        body: payload,
        signal: AbortSignal.timeout(170_000),
      });
    } catch (error) {
      // No retry: when a request throws, the provider may or may not have
      // read it, and a second attempt could be billed on top of the first
      // without ever being metered. A timeout in particular means the model
      // was probably still generating, so it is charged as a full worst case.
      const name = error instanceof Error ? error.name : "";
      throw new UpstreamFailure(
        name === "TimeoutError" || name === "AbortError" ? "timeout" : "network",
        "Could not get a reply from the model provider.",
      );
    }

    if (response.ok) return parseReply(await response.json().catch(() => null));

    lastStatus = response.status;
    const retryAfter = Number(response.headers.get("retry-after"));
    await response.arrayBuffer().catch(() => undefined); // drain, never forwarded
    if (RETRYABLE.has(response.status) && attempt < ATTEMPTS) {
      const wait = Number.isFinite(retryAfter) && retryAfter > 0 ? Math.min(retryAfter, 5) * 1000 : 500 * attempt;
      await deps.sleep(wait);
      continue;
    }
    break;
  }
  throw new UpstreamFailure(lastStatus === 429 || lastStatus === 529 ? "busy" : "http", `Provider returned ${lastStatus}.`, lastStatus);
}

function parseReply(json: unknown): ModelReply {
  if (typeof json !== "object" || json === null) throw new UpstreamFailure("bad_response", "Unreadable provider reply.");
  const data = json as Record<string, unknown>;
  const usage = (data.usage ?? {}) as Record<string, unknown>;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  // Cache reads and writes count as input here, which can only overstate cost.
  const inputTokens = num(usage.input_tokens) + num(usage.cache_creation_input_tokens) + num(usage.cache_read_input_tokens);
  const outputTokens = num(usage.output_tokens);
  const stopReason = typeof data.stop_reason === "string" ? data.stop_reason : null;

  if (stopReason === "refusal") {
    throw new UpstreamFailure("refused", "The model declined this request.", 200, inputTokens, outputTokens);
  }
  const blocks = Array.isArray(data.content) ? (data.content as Array<Record<string, unknown>>) : [];
  // Thinking blocks have no "text" key, so they drop out here.
  const text = blocks.map((b) => (typeof b.text === "string" ? b.text : "")).join("");
  if (!text) {
    throw new UpstreamFailure(
      stopReason === "max_tokens" ? "truncated" : "bad_response",
      "The model returned no text.",
      200,
      inputTokens,
      outputTokens,
    );
  }
  return { text, inputTokens, outputTokens, stopReason };
}
