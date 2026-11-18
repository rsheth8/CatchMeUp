import { callModel, UpstreamFailure, type ModelReply } from "../anthropic";
import { loadConfig } from "../config";
import { requireUser, type Ctx } from "../context";
import { ApiError, json, log, readJsonObject, stringField } from "../http";
import { diagnose, fail, reserve, settle, type Rejection } from "../ledger";
import { MAX_CALLS_PER_JOB, nextPeriodStart } from "../plans";
import { costMicro, effectiveMaxTokens, inputOnlyMicro, reserveMicro } from "../pricing";
import { planFor, quotaFor } from "../users";

/** What the app is asking for. The server only allows labels it knows. */
const TASKS = new Set(["recap", "answer", "meeting", "questions", "materials", "other"]);
/**
 * These tasks write the notes for a recording, so they count as one recap per
 * recording (identified by `jobId`). The rest use budget only.
 */
const RECAP_TASKS = new Set(["recap", "meeting"]);

const REJECTIONS: Record<Rejection, { status: number; message: string }> = {
  quota_exceeded: { status: 402, message: "You have used this month's recaps." },
  job_limit: { status: 429, message: "This recording has used its processing allowance for the month." },
  rate_limited: { status: 429, message: "Too many requests. Wait a minute and try again." },
  request_in_flight: { status: 429, message: "Another request is still running. Try again in a moment." },
  service_busy: { status: 503, message: "CatchMeUp Cloud is at capacity right now. Try again later, or use on-device mode." },
};

const utf8Length = (text: string) => new TextEncoder().encode(text).length;

/**
 * Runs one model call for a signed-in user, inside their limits.
 *
 * The caller supplies the prompt text, but not the model, the sampling
 * settings or the output ceiling. Every limit is checked and a worst-case
 * cost reserved in one database statement before the provider is contacted,
 * then replaced with the real cost afterwards.
 */
export async function recap(request: Request, ctx: Ctx): Promise<Response> {
  const user = await requireUser(request, ctx);
  const cfg = loadConfig(ctx.env);

  // The raw body is capped first, while streaming (a JSON string can spend up
  // to 6 bytes escaping one character). Size is then judged on the combined
  // prompt below, so "too long" is one clear 413 the app can explain.
  const maxBody = cfg.maxInputBytes * 6 + 4_096;
  const body = await readJsonObject(request, maxBody);
  const task = stringField(body, "task", { max: 32 });
  if (!TASKS.has(task)) throw new ApiError(400, "bad_request", `Unknown task "${task}".`);
  const system = stringField(body, "system", { max: maxBody });
  const userText = stringField(body, "user", { max: maxBody });
  const inputBytes = utf8Length(system) + utf8Length(userText);
  if (inputBytes > cfg.maxInputBytes) {
    throw new ApiError(413, "input_too_large", "That recording is too long to process in one request.", {
      maxInputBytes: cfg.maxInputBytes,
    });
  }
  let jobId: string | null = null;
  if (RECAP_TASKS.has(task)) {
    jobId = stringField(body, "jobId", { min: 8, max: 64 });
    if (!/^[A-Za-z0-9_-]+$/.test(jobId)) throw new ApiError(400, "bad_request", '"jobId" must be letters, digits, "-" or "_".');
  }
  const requested = body.maxTokens === undefined ? 4_096 : body.maxTokens;
  if (typeof requested !== "number" || !Number.isInteger(requested) || requested < 1) {
    throw new ApiError(400, "bad_request", '"maxTokens" must be a positive integer.');
  }

  const plan = await planFor(ctx.env.DB, user.id, ctx.now);
  // The plan, not the app, decides the model.
  const model = cfg.models[plan.id];
  const maxTokens = effectiveMaxTokens(model, requested, cfg.maxOutputTokens);
  const reservation = {
    id: crypto.randomUUID(),
    userId: user.id,
    task,
    model,
    reserveMicro: reserveMicro(model, inputBytes, maxTokens),
    nowMs: ctx.now,
    plan,
    globalDailyBudgetMicro: cfg.globalDailyBudgetMicro,
    rateLimitPerMinute: cfg.rateLimitPerMinute,
    jobId,
    maxCallsPerJob: MAX_CALLS_PER_JOB,
  };

  if (!(await reserve(ctx.env.DB, reservation))) {
    const reason = await diagnose(ctx.env.DB, reservation);
    log("recap_refused", { reason, plan: plan.id, requestId: ctx.requestId });
    const { status, message } = REJECTIONS[reason];
    throw new ApiError(
      status,
      reason,
      message,
      reason === "quota_exceeded" ? { plan: plan.id, resetsAt: nextPeriodStart(ctx.now) } : {},
      reason === "service_busy" || reason === "rate_limited" ? { "retry-after": "60" } : {},
    );
  }

  // The model call and its accounting run as one unit that is handed to
  // waitUntil, so a client that disconnects cannot cancel the bookkeeping
  // halfway and leave a billed call unrecorded.
  const work = (async (): Promise<ModelReply> => {
    let reply: ModelReply;
    try {
      reply = await callModel(ctx.deps, cfg, { model, system, user: userText, maxTokens });
    } catch (error) {
      await recordFailure(ctx, reservation.id, model, inputBytes, reservation.reserveMicro, error);
      throw error;
    }
    await settle(
      ctx.env.DB,
      reservation.id,
      {
        costMicro: costMicro(model, reply.inputTokens, reply.outputTokens),
        inputTokens: reply.inputTokens,
        outputTokens: reply.outputTokens,
      },
      ctx.deps.now(),
    );
    return reply;
  })();
  ctx.waitUntil(work.then(() => undefined, () => undefined));

  let reply: ModelReply;
  try {
    reply = await work;
  } catch (error) {
    throw toApiError(error, ctx.requestId);
  }

  log("recap_ok", {
    task,
    plan: plan.id,
    model,
    inputTokens: reply.inputTokens,
    outputTokens: reply.outputTokens,
    requestId: ctx.requestId,
  });
  return json({ text: reply.text, quota: await quotaFor(ctx.env.DB, user.id, plan, ctx.now) });
}

/**
 * Marks a failed call and charges what it may have cost. Tokens the provider
 * reported are charged exactly. A timeout is charged the whole reservation,
 * since the model was probably still generating. A connection error is charged
 * the input side only. An answer that says it did no work (a 4xx or 5xx) is
 * free.
 */
async function recordFailure(
  ctx: Ctx,
  id: string,
  model: string,
  inputBytes: number,
  reservedMicro: number,
  error: unknown,
): Promise<void> {
  let cost = 0;
  let inputTokens = 0;
  let outputTokens = 0;
  if (error instanceof UpstreamFailure) {
    inputTokens = error.inputTokens;
    outputTokens = error.outputTokens;
    if (inputTokens > 0 || outputTokens > 0) cost = costMicro(model, inputTokens, outputTokens);
    else if (error.kind === "timeout") cost = reservedMicro;
    else if (error.kind === "network") cost = inputOnlyMicro(model, inputBytes);
  } else {
    // An unexpected error after the provider was contacted: assume the worst.
    cost = reservedMicro;
  }
  await fail(ctx.env.DB, id, { costMicro: cost, inputTokens, outputTokens }, ctx.deps.now());
}

function toApiError(error: unknown, requestId: string): ApiError {
  if (error instanceof UpstreamFailure) {
    log("recap_upstream_failure", { kind: error.kind, status: error.status, requestId });
    if (error.kind === "busy") {
      return new ApiError(503, "model_busy", "The model is busy right now. Try again in a moment.", {}, { "retry-after": "30" });
    }
    if (error.kind === "refused") return new ApiError(422, "refused", "The model declined to process this recording.");
    if (error.kind === "truncated") return new ApiError(502, "truncated", "The recap was cut off. Try again, or split the recording.");
  }
  return new ApiError(502, "upstream_error", "The model could not complete this request.");
}
