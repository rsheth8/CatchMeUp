import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  API_KEY,
  RECAP_BODY,
  SONNET_OK_COST,
  START,
  db,
  grantPlus,
  ledgerRows,
  makeApp,
  migrate,
  okBody,
  resetDatabase,
} from "./helpers";

beforeAll(migrate);
beforeEach(resetDatabase);
afterEach(() => vi.restoreAllMocks());

async function setup(overrides = {}) {
  const app = await makeApp(overrides);
  const session = await app.signInApple();
  const recap = (body: unknown = RECAP_BODY, token = session.accessToken) => app.call("POST", "/v1/recap", { body, token });
  return { app, session, recap };
}

describe("a recap request", () => {
  it("calls the model as the server decides and returns the text with the remaining quota", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 200, body: okBody("RECAP TEXT") }];

    const res = await recap({ ...RECAP_BODY, model: "claude-opus-5-5", temperature: 1 });
    expect(res.status).toBe(200);
    expect(res.json.text).toBe("RECAP TEXT");
    expect(res.json.quota).toMatchObject({ plan: "free", recapsRemaining: 2, resetsAt: "2026-12-01T00:00:00.000Z" });

    expect(app.net.upstreamCalls).toHaveLength(1);
    const call = app.net.upstreamCalls[0]!;
    expect(call.headers.get("x-api-key")).toBe(API_KEY);
    expect(call.headers.get("anthropic-version")).toBe("2023-06-01");
    expect(call.body.model).toBe("claude-sonnet-5-5"); // the client's choice is ignored
    expect(call.body.temperature).toBeUndefined();
    expect(call.body.top_p).toBeUndefined();
    expect(call.body.output_config).toEqual({ effort: "medium" });
    expect(call.body.max_tokens).toBe(16_000); // thinking headroom over the requested 4,096
    expect(call.body.system).toBe("s");
    expect(call.body.messages).toEqual([{ role: "user", content: "u" }]);
  });

  it("records the real cost against the user's usage", async () => {
    const { recap } = await setup();
    await recap();
    const rows = await ledgerRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      status: "settled",
      cost_micro: SONNET_OK_COST,
      input_tokens: 1000,
      output_tokens: 500,
      model: "claude-sonnet-5-5",
      task: "recap",
      period: "2026-11",
      day: "2026-11-18",
    });
  });

  it("sends no effort to a model that does not accept it", async () => {
    const { app, recap } = await setup({ RECAP_MODEL_FREE: "claude-haiku-4-5-20251001" });
    await recap();
    const call = app.net.upstreamCalls[0]!;
    expect(call.body.output_config).toBeUndefined();
    expect(call.body.max_tokens).toBe(4_096);
  });

  it("joins thinking blocks out of the reply", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{
      status: 200,
      body: { stop_reason: "end_turn", content: [{ type: "thinking", thinking: "hmm" }, { type: "text", text: "A" }, { type: "text", text: "B" }], usage: { input_tokens: 10, output_tokens: 10 } },
    }];
    expect((await recap()).json.text).toBe("AB");
  });
});

describe("the free plan", () => {
  it("allows three recaps a month and refuses the fourth without calling the model", async () => {
    const { app, recap } = await setup();
    for (let i = 0; i < 3; i++) expect((await recap()).status).toBe(200);
    expect(app.net.upstreamCalls).toHaveLength(3);

    const fourth = await recap();
    expect(fourth.status).toBe(402);
    expect(fourth.json.error).toMatchObject({ code: "quota_exceeded", plan: "free", resetsAt: "2026-12-01T00:00:00.000Z" });
    expect(app.net.upstreamCalls).toHaveLength(3);
  });

  it("starts fresh on the first of the next month", async () => {
    const { app, recap } = await setup();
    for (let i = 0; i < 3; i++) await recap();
    expect((await recap()).status).toBe(402);

    app.clock.now = Date.UTC(2026, 11, 1, 0, 0, 1);
    // The access token has expired by then, so the app refreshes first.
    const session = await app.signInApple();
    const res = await recap(RECAP_BODY, session.accessToken);
    expect(res.status).toBe(200);
    expect(res.json.quota.recapsRemaining).toBe(2);
  });

  it("shows three left to a new user", async () => {
    const { app, session } = await setup();
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.json.quota).toMatchObject({ plan: "free", recapsRemaining: 3 });
  });
});

describe("the Plus plan", () => {
  it("goes past the free limit while a subscription is active", async () => {
    const { app, session, recap } = await setup();
    await grantPlus(session.userId, START + 30 * 86_400_000);
    for (let i = 0; i < 5; i++) expect((await recap()).status).toBe(200);
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.json.quota.plan).toBe("plus");
    expect(me.json.quota.recapsRemaining).toBeGreaterThan(50);
  });

  it("falls back to free the moment the subscription lapses", async () => {
    const { app, session, recap } = await setup();
    await grantPlus(session.userId, START + 1_000);
    expect((await recap()).status).toBe(200);
    app.clock.now = START + 2_000;
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.json.quota.plan).toBe("free");
  });

  it("stops at its dollar budget even with recaps to spare", async () => {
    const { app, session, recap } = await setup();
    await grantPlus(session.userId, START + 30 * 86_400_000);
    // Spend the monthly budget on earlier, finished calls.
    await db()
      .prepare("INSERT INTO ledger (id, user_id, period, day, task, model, status, reserved_micro, cost_micro, created_at) VALUES ('old', ?1, '2026-11', '2026-11-02', 'recap', 'claude-sonnet-5-5', 'settled', 0, 3600000, ?2)")
      .bind(session.userId, START - 86_400_000)
      .run();
    const res = await recap();
    expect(res.status).toBe(402);
    expect(res.json.error).toMatchObject({ code: "quota_exceeded", plan: "plus" });
    expect(app.net.upstreamCalls).toHaveLength(0);
  });
});

describe("spend limits", () => {
  it("shuts everyone out once the day's global budget is used, then recovers next day", async () => {
    // $0.17: room for two recaps' worth of reservation plus settled spend, not three.
    const { app, recap } = await setup({ GLOBAL_DAILY_BUDGET_USD: "0.17" });
    expect((await recap()).status).toBe(200);
    expect((await recap()).status).toBe(200);
    const third = await recap();
    expect(third.status).toBe(503);
    expect(third.json.error.code).toBe("service_busy");
    expect(third.headers.get("retry-after")).toBe("60");
    expect(app.net.upstreamCalls).toHaveLength(2);

    // A different user is shut out too: it is a global limit.
    const other = await app.signInApple("someone-else");
    expect((await recap(RECAP_BODY, other.accessToken)).status).toBe(503);

    app.clock.now += 24 * 3600 * 1000;
    const next = await app.signInApple("someone-else");
    expect((await recap(RECAP_BODY, next.accessToken)).status).toBe(200);
  });

  it("limits requests per minute", async () => {
    const { app, session, recap } = await setup({ RATE_LIMIT_PER_MINUTE: "2" });
    await grantPlus(session.userId, START + 30 * 86_400_000);
    expect((await recap()).status).toBe(200);
    expect((await recap()).status).toBe(200);
    const third = await recap();
    expect(third.status).toBe(429);
    expect(third.json.error.code).toBe("rate_limited");
    expect(third.headers.get("retry-after")).toBe("60");

    app.clock.now += 61_000;
    const session2 = await app.signInApple();
    expect((await recap(RECAP_BODY, session2.accessToken)).status).toBe(200);
  });

  it("lets only as many requests run at once as the budget can cover, and no more", async () => {
    const { app, recap } = await setup();
    let release!: () => void;
    app.net.gate = new Promise<void>((resolve) => (release = resolve));

    // Free budget is $0.60 and each reservation is about $0.16, so three fit.
    const inFlight = Promise.all([recap(), recap(), recap(), recap()]);
    await new Promise((r) => setTimeout(r, 150));
    release();
    const results = await inFlight;

    expect(results.map((r) => r.status).sort()).toEqual([200, 200, 200, 429]);
    expect(results.filter((r) => r.status === 429).every((r) => r.json.error.code === "request_in_flight")).toBe(true);
    const rows = await ledgerRows();
    expect(rows.filter((r) => r.status === "settled")).toHaveLength(3);
    expect(rows.filter((r) => r.status === "pending")).toHaveLength(0);
  });

  it("treats a reservation from a request that died as no longer in flight after ten minutes", async () => {
    const { app, session, recap } = await setup();
    const insert = (id: string, createdAt: number, reserved = 390_000) =>
      db()
        .prepare("INSERT INTO ledger (id, user_id, period, day, task, model, status, reserved_micro, created_at) VALUES (?1, ?2, '2026-11', '2026-11-18', 'recap', 'claude-sonnet-5-5', 'pending', ?3, ?4)")
        .bind(id, session.userId, reserved, createdAt)
        .run();

    // 0.45 + 0.16 would pass a $0.60 budget only if the 0.45 were released.
    await insert("fresh", START - 60_000, 450_000);
    const blocked = await recap();
    expect(blocked.status).toBe(429);
    expect(blocked.json.error.code).toBe("request_in_flight");

    await db().prepare("DELETE FROM ledger").run();
    await insert("stale", START - 11 * 60_000, 390_000);
    expect((await recap()).status).toBe(200);
    expect(app.net.upstreamCalls).toHaveLength(1);
  });

  it("keeps charging an orphaned reservation at its worst case, so walking away is never free", async () => {
    const { app, session, recap } = await setup();
    await db()
      .prepare("INSERT INTO ledger (id, user_id, period, day, task, model, status, reserved_micro, created_at) VALUES ('orphan', ?1, '2026-11', '2026-11-18', 'recap', 'claude-sonnet-5-5', 'pending', 500000, ?2)")
      .bind(session.userId, START - 11 * 60_000)
      .run();
    // 0.50 already held plus 0.16 for this call is over the free $0.60 budget.
    const res = await recap();
    expect(res.status).toBe(402);
    expect(res.json.error.code).toBe("quota_exceeded");
    expect(app.net.upstreamCalls).toHaveLength(0);
  });

  it("counts an orphaned reservation against the global daily budget too", async () => {
    const { app, session, recap } = await setup({ GLOBAL_DAILY_BUDGET_USD: "0.30" });
    const other = await app.signInApple("other-user");
    await db()
      .prepare("INSERT INTO ledger (id, user_id, period, day, task, model, status, reserved_micro, created_at) VALUES ('orphan', ?1, '2026-11', '2026-11-18', 'recap', 'claude-sonnet-5-5', 'pending', 200000, ?2)")
      .bind(other.userId, START - 11 * 60_000)
      .run();
    const res = await recap(RECAP_BODY, session.accessToken);
    expect(res.status).toBe(503);
    expect(res.json.error.code).toBe("service_busy");
  });

  it("reserves from the prompt's byte size, so a bigger prompt is held against more budget", async () => {
    const { app, recap } = await setup();
    await recap({ ...RECAP_BODY, user: "x".repeat(120_000) });
    const [row] = await ledgerRows();
    // (120,001 bytes + 1,000 framing) x $2/M + 16,000 x $10/M
    expect(row!.reserved_micro).toBe(121_001 * 2 + 160_000);
    expect(app.net.upstreamCalls).toHaveLength(1);
  });

  it("refuses a prompt whose worst case the free budget cannot cover, before calling the model", async () => {
    // With the cap raised, 250,000 bytes reserves about $0.50 of input plus $0.16 of output.
    const { app, recap } = await setup({ MAX_INPUT_BYTES: "400000" });
    const res = await recap({ ...RECAP_BODY, user: "x".repeat(250_000) });
    expect(res.status).toBe(402);
    expect(app.net.upstreamCalls).toHaveLength(0);
  });
});

describe("when the model call fails", () => {
  it("retries a busy model and then succeeds", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 429, body: {}, headers: { "retry-after": "1" } }, { status: 200, body: okBody() }];
    expect((await recap()).status).toBe(200);
    expect(app.net.upstreamCalls).toHaveLength(2);
  });

  it("gives up on a model that keeps failing, without using up a recap", async () => {
    const { app, recap, session } = await setup();
    app.net.upstream = [{ status: 500, body: { error: "secret upstream detail" } }];
    const res = await recap();
    expect(res.status).toBe(502);
    expect(res.json.error.code).toBe("upstream_error");
    expect(res.text).not.toContain("secret upstream detail");
    expect(app.net.upstreamCalls).toHaveLength(3);

    const rows = await ledgerRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ status: "failed", cost_micro: 0 });
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.json.quota.recapsRemaining).toBe(3);
  });

  it("does not retry a client error", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 400, body: { error: "bad" } }];
    expect((await recap()).status).toBe(502);
    expect(app.net.upstreamCalls).toHaveLength(1);
  });

  it("does not retry a call that timed out, and charges its full reservation", async () => {
    const { app, recap, session } = await setup();
    app.net.upstream = [{ status: 200, body: okBody(), throws: "timeout" }];
    const res = await recap();
    expect(res.status).toBe(502);
    expect(app.net.upstreamCalls).toHaveLength(1); // a second try could be billed unmetered

    const [row] = await ledgerRows();
    expect(row).toMatchObject({ status: "failed" });
    expect(row!.cost_micro).toBe(row!.reserved_micro);
    expect(row!.cost_micro).toBeGreaterThan(0);
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.json.quota.recapsRemaining).toBe(3); // not a recap, but the dollars stay spent
  });

  it("does not retry a dropped connection, and charges the input side", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 200, body: okBody(), throws: "network" }];
    const res = await recap();
    expect(res.status).toBe(502);
    expect(app.net.upstreamCalls).toHaveLength(1);

    const [row] = await ledgerRows();
    expect(row).toMatchObject({ status: "failed", cost_micro: (2 + 1_000) * 2 }); // 2 bytes + framing at $2/M
  });

  it("stops serving a user whose timeouts have used the dollar budget", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 200, body: okBody(), throws: "timeout" }];
    const statuses: number[] = [];
    for (let i = 0; i < 5; i++) statuses.push((await recap()).status);
    // Each timeout costs about $0.16 of the $0.60 free budget: three run, then it is closed.
    expect(statuses).toEqual([502, 502, 502, 402, 402]);
    expect(app.net.upstreamCalls).toHaveLength(3);
  });

  it("reports a model that stays overloaded as busy, with a retry hint", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 529, body: {} }];
    const res = await recap();
    expect(res.status).toBe(503);
    expect(res.json.error.code).toBe("model_busy");
    expect(res.headers.get("retry-after")).toBe("30");
  });

  it("charges the spend of a cut-off reply but not a recap", async () => {
    const { app, recap, session } = await setup();
    app.net.upstream = [{ status: 200, body: { stop_reason: "max_tokens", content: [], usage: { input_tokens: 1000, output_tokens: 16000 } } }];
    const res = await recap();
    expect(res.status).toBe(502);
    expect(res.json.error.code).toBe("truncated");

    const rows = await ledgerRows();
    expect(rows[0]).toMatchObject({ status: "failed", cost_micro: 1000 * 2 + 16000 * 10 });
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.json.quota.recapsRemaining).toBe(3);
  });

  it("reports a refusal", async () => {
    const { app, recap } = await setup();
    app.net.upstream = [{ status: 200, body: { stop_reason: "refusal", content: [], usage: { input_tokens: 10, output_tokens: 0 } } }];
    const res = await recap();
    expect(res.status).toBe(422);
    expect(res.json.error.code).toBe("refused");
  });
});

describe("request checks", () => {
  it("requires sign-in", async () => {
    const { app } = await setup();
    expect((await app.call("POST", "/v1/recap", { body: RECAP_BODY })).status).toBe(401);
    expect(app.net.upstreamCalls).toHaveLength(0);
  });

  it.each([
    ["an unknown task", { ...RECAP_BODY, task: "write-my-essay" }],
    ["a missing system prompt", { task: "recap", user: "u" }],
    ["an empty user prompt", { ...RECAP_BODY, user: "" }],
    ["a fractional maxTokens", { ...RECAP_BODY, maxTokens: 10.5 }],
    ["a negative maxTokens", { ...RECAP_BODY, maxTokens: -1 }],
    ["a string maxTokens", { ...RECAP_BODY, maxTokens: "lots" }],
  ])("rejects %s with 400 and never reaches the model", async (_name, body) => {
    const { app, recap } = await setup();
    const res = await recap(body);
    expect(res.status).toBe(400);
    expect(app.net.upstreamCalls).toHaveLength(0);
    expect(await ledgerRows()).toHaveLength(0);
  });

  it("rejects bodies that are not JSON objects", async () => {
    const { app, session } = await setup();
    for (const raw of ["not json", "[]", "5", "null"]) {
      const res = await app.call("POST", "/v1/recap", { raw, token: session.accessToken });
      expect(res.status).toBe(400);
    }
  });

  it("refuses input longer than the limit", async () => {
    const { app, recap } = await setup({ MAX_INPUT_BYTES: "1000" });
    const res = await recap({ ...RECAP_BODY, user: "x".repeat(2_000) });
    expect(res.status).toBe(413);
    expect(res.json.error.code).toBe("input_too_large");
    expect(app.net.upstreamCalls).toHaveLength(0);
    expect(await ledgerRows()).toHaveLength(0);
  });

  it("counts the limit in UTF-8 bytes, not characters", async () => {
    const { app, recap } = await setup({ MAX_INPUT_BYTES: "1000" });
    // 400 characters, 1,200 bytes: under a character limit, over the byte limit.
    const res = await recap({ ...RECAP_BODY, user: "講".repeat(400) });
    expect(res.status).toBe(413);
    expect(app.net.upstreamCalls).toHaveLength(0);
    expect((await recap({ ...RECAP_BODY, user: "講".repeat(100) })).status).toBe(200);
  });

  it("adds the system prompt and the user text together", async () => {
    const { app, recap } = await setup({ MAX_INPUT_BYTES: "1000" });
    const res = await recap({ ...RECAP_BODY, system: "s".repeat(600), user: "u".repeat(600) });
    expect(res.status).toBe(413);
    expect(app.net.upstreamCalls).toHaveLength(0);
  });

  it("refuses an oversized body outright", async () => {
    const { app, session } = await setup({ MAX_INPUT_BYTES: "1000" });
    const res = await app.call("POST", "/v1/recap", { raw: JSON.stringify({ ...RECAP_BODY, user: "x".repeat(50_000) }), token: session.accessToken });
    expect(res.status).toBe(413);
  });

  it("stops reading a body that is bigger than it claims, without buffering it all", async () => {
    const { app, session } = await setup({ MAX_INPUT_BYTES: "1000" });
    // No content-length is sent for a stream, so only the streaming cap can stop this.
    const chunk = new TextEncoder().encode("x".repeat(8_192));
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        sent += chunk.length;
        controller.enqueue(chunk);
        if (sent > 5_000_000) controller.close();
      },
    });
    const response = await (await import("../src/index")).makeHandler({ fetch: app.net.fetch, now: () => app.clock.now, sleep: async () => {} }).fetch!(
      new Request("https://api.test/v1/recap", {
        method: "POST",
        headers: { authorization: `Bearer ${session.accessToken}`, "content-type": "application/json" },
        body: stream,
        // @ts-expect-error duplex is required for stream bodies and missing from the DOM types
        duplex: "half",
      }) as any,
      app.env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(response.status).toBe(413);
    expect(sent).toBeLessThan(1_000_000);
    expect(app.net.upstreamCalls).toHaveLength(0);
  });

  it("caps maxTokens at the server's ceiling", async () => {
    const { app, recap } = await setup({ MAX_OUTPUT_TOKENS: "6000" });
    await recap({ ...RECAP_BODY, maxTokens: 100_000 });
    expect(app.net.upstreamCalls[0]!.body.max_tokens).toBe(6_000);
  });

  it("answers health checks, unknown paths and wrong methods", async () => {
    const { app } = await setup();
    expect((await app.call("GET", "/health")).status).toBe(200);
    expect((await app.call("GET", "/nope")).status).toBe(404);
    expect((await app.call("GET", "/v1/recap")).status).toBe(405);
  });
});

describe("misconfiguration fails closed", () => {
  it.each([
    ["an unpriced free model", { RECAP_MODEL_FREE: "claude-mystery-1" }],
    ["an unpriced Plus model", { RECAP_MODEL_PLUS: "claude-mystery-1" }],
    ["no free model", { RECAP_MODEL_FREE: "" }],
    ["no API key", { ANTHROPIC_API_KEY: "" }],
    ["a zero global budget", { GLOBAL_DAILY_BUDGET_USD: "0" }],
    ["a garbage limit", { RATE_LIMIT_PER_MINUTE: "lots" }],
  ])("refuses to serve with %s", async (_name, overrides) => {
    const { app, recap } = await setup(overrides);
    const res = await recap();
    expect(res.status).toBe(500);
    expect(res.json.error.code).toBe("misconfigured");
    expect(app.net.upstreamCalls).toHaveLength(0);
  });
});

describe("secrets and content stay out of logs and responses", () => {
  it("never logs or returns the API key, the tokens or the transcript", async () => {
    const lines: string[] = [];
    vi.spyOn(console, "log").mockImplementation((...args) => void lines.push(args.map(String).join(" ")));
    vi.spyOn(console, "error").mockImplementation((...args) => void lines.push(args.map(String).join(" ")));

    const { app, session, recap } = await setup();
    const secretTranscript = "the-private-lecture-content-12345";
    const ok = await recap({ ...RECAP_BODY, user: secretTranscript });
    app.net.upstream = [{ status: 500, body: { error: secretTranscript } }];
    const failed = await recap({ ...RECAP_BODY, user: secretTranscript });
    const refused = await recap({ ...RECAP_BODY, task: "bogus", user: secretTranscript });

    const everything = [...lines, ok.text, failed.text, refused.text].join("\n");
    for (const secret of [API_KEY, session.accessToken, session.refreshToken, secretTranscript]) {
      expect(everything).not.toContain(secret);
    }
    expect(lines.length).toBeGreaterThan(0);
  });
});

describe("model by plan", () => {
  // The production split, not the shared test default.
  const split = { RECAP_MODEL_FREE: "claude-haiku-5-5", RECAP_MODEL_PLUS: "claude-sonnet-5-5" };

  it("gives free users Haiku and Plus users Sonnet, and prices each on its own rates", async () => {
    const { app, session, recap } = await setup(split);
    await recap();
    expect(app.net.upstreamCalls[0]!.body.model).toBe("claude-haiku-5-5");
    // 1,000 in at $0.10/M and 500 out at $0.50/M, rounded up: 0.1 + 0.25 -> 1 micro-dollar each side.
    const rowFor = async (model: string) => (await ledgerRows()).find((r) => r.model === model);
    expect(await rowFor("claude-haiku-5-5")).toMatchObject({ status: "settled", cost_micro: 1_000 * 0.1 + 500 * 0.5 });

    await grantPlus(session.userId, START + 30 * 86_400_000);
    await recap();
    expect(app.net.upstreamCalls[1]!.body.model).toBe("claude-sonnet-5-5");
    expect(await rowFor("claude-sonnet-5-5")).toMatchObject({ status: "settled", cost_micro: SONNET_OK_COST });
  });

  it("switches model the moment a subscription starts or lapses", async () => {
    const { app, session, recap } = await setup(split);
    await grantPlus(session.userId, START + 1_000);
    await recap();
    app.clock.now = START + 2_000;
    await recap();
    expect(app.net.upstreamCalls.map((c) => c.body.model)).toEqual(["claude-sonnet-5-5", "claude-haiku-5-5"]);
  });

  it("ignores a model named by the client for either plan", async () => {
    const { app, recap } = await setup(split);
    await recap({ ...RECAP_BODY, model: "claude-opus-5-5" });
    expect(app.net.upstreamCalls[0]!.body.model).toBe("claude-haiku-5-5");
  });

  it("sends Haiku 5.5 an effort setting and thinking headroom, like the other 5-series models", async () => {
    const { app, recap } = await setup(split);
    await recap();
    expect(app.net.upstreamCalls[0]!.body.output_config).toEqual({ effort: "medium" });
    expect(app.net.upstreamCalls[0]!.body.max_tokens).toBe(16_000);
  });
});
