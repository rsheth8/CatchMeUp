import { callModel, UpstreamFailure } from "../anthropic";
import { loadConfig } from "../config";
import { requireUser, type Ctx } from "../context";
import { ApiError, json, log, readJsonObject, stringField } from "../http";
import { diagnose, fail, reserve, settle, type Rejection } from "../ledger";
import { nextPeriodStart } from "../plans";
import { costMicro, effectiveMaxTokens, reserveMicro } from "../pricing";
import { planFor, quotaFor } from "../users";

/** What the app is asking for. The server only allows labels it knows. */
const TASKS = new Set(["recap", "answer", "meeting", "questions", "materials", "other"]);

const REJECTIONS: Record<Rejection, { status: number; message: string }> = {
  quota_exceeded: { status: 402, message: "You have used this month's recaps." },
  rate_limited: { status: 429, message: "Too many requests. Wait a minute and try again." },
  request_in_flight: { status: 429, message: "Another request is still running. Try again in a moment." },
  service_busy: { status: 503, message: "CatchMeUp Cloud is at capacity right now. Try again later, or use on-device mode." },
};

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

  // The raw body is capped first (up to 4 bytes a character, plus JSON overhead).
  // Length is then judged on the combined prompt below, so "too long" is one
  // clear 413 the app can explain, not a 400 about a single field.
  const maxBody = Math.ceil(cfg.maxInputChars * 4) + 4_096;
  const body = await readJsonObject(request, maxBody);
  const task = stringField(body, "task", { max: 32 });
  if (!TASKS.has(task)) throw new ApiError(400, "bad_request", `Unknown task "${task}".`);
  const system = stringField(body, "system", { max: maxBody });
  const userText = stringField(body, "user", { max: maxBody });
  if (system.length + userText.length > cfg.maxInputChars) {
    throw new ApiError(413, "input_too_large", "That recording is too long to process in one request.", {
      maxInputChars: cfg.maxInputChars,
    });
  }
  const requested = body.maxTokens === undefined ? 4_096 : body.maxTokens;
  if (typeof requested !== "number" || !Number.isInteger(requested) || requested < 1) {
    throw new ApiError(400, "bad_request", '"maxTokens" must be a positive integer.');
  }

  const maxTokens = effectiveMaxTokens(cfg.model, requested, cfg.maxOutputTokens);
  const plan = await planFor(ctx.env.DB, user.id, ctx.now);
  const reservation = {
    id: crypto.randomUUID(),
    userId: user.id,
    task,
    model: cfg.model,
    reserveMicro: reserveMicro(cfg.model, system.length + userText.length, maxTokens),
    nowMs: ctx.now,
    plan,
    globalDailyBudgetMicro: cfg.globalDailyBudgetMicro,
    rateLimitPerMinute: cfg.rateLimitPerMinute,
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

  let reply;
  try {
    reply = await callModel(ctx.deps, cfg, { system, user: userText, maxTokens });
  } catch (error) {
    const usage = error instanceof UpstreamFailure
      ? { inputTokens: error.inputTokens, outputTokens: error.outputTokens }
      : { inputTokens: 0, outputTokens: 0 };
    await fail(
      ctx.env.DB,
      reservation.id,
      { ...usage, costMicro: costMicro(cfg.model, usage.inputTokens, usage.outputTokens) },
      ctx.deps.now(),
    );
    if (error instanceof UpstreamFailure) {
      log("recap_upstream_failure", { kind: error.kind, status: error.status, requestId: ctx.requestId });
      if (error.kind === "busy") {
        throw new ApiError(503, "model_busy", "The model is busy right now. Try again in a moment.", {}, { "retry-after": "30" });
      }
      if (error.kind === "refused") {
        throw new ApiError(422, "refused", "The model declined to process this recording.");
      }
      if (error.kind === "truncated") {
        throw new ApiError(502, "truncated", "The recap was cut off. Try again, or split the recording.");
      }
    }
    throw new ApiError(502, "upstream_error", "The model could not complete this request. You were not charged a recap.");
  }

  await settle(
    ctx.env.DB,
    reservation.id,
    {
      costMicro: costMicro(cfg.model, reply.inputTokens, reply.outputTokens),
      inputTokens: reply.inputTokens,
      outputTokens: reply.outputTokens,
    },
    ctx.deps.now(),
  );
  log("recap_ok", {
    task,
    plan: plan.id,
    inputTokens: reply.inputTokens,
    outputTokens: reply.outputTokens,
    requestId: ctx.requestId,
  });

  return json({ text: reply.text, quota: await quotaFor(ctx.env.DB, user.id, plan, ctx.now) });
}
