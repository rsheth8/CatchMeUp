import { applyD1Migrations, createExecutionContext, env as workerEnv } from "cloudflare:test";
import { exportJWK, generateKeyPair, SignJWT, type JWK, type CryptoKey } from "jose";
import type { Env } from "../src/env";
import { makeHandler } from "../src/index";

export const API_KEY = "sk-test-key-do-not-leak";
export const START = Date.UTC(2026, 10, 18, 12, 0, 0); // 18 Nov 2026, noon UTC
export const SONNET_OK_COST = 7_000; // 1,000 in at $2/M + 500 out at $10/M, in micro-dollars

const APPLE_JWKS = "https://jwks.test/apple";
const GOOGLE_JWKS = "https://jwks.test/google";
const UPSTREAM = "https://anthropic.test";

export function okBody(text = '{"title":"T"}', usage = { input_tokens: 1000, output_tokens: 500 }, stop = "end_turn") {
  return { stop_reason: stop, content: [{ type: "text", text }], usage };
}

export interface Upstream {
  status: number;
  body: unknown;
  headers?: Record<string, string>;
}

export interface RecordedCall {
  url: string;
  headers: Headers;
  body: Record<string, any>;
}

/** An in-memory stand-in for Apple's and Google's key servers and for Anthropic. */
export class FakeNet {
  appleKey!: CryptoKey;
  googleKey!: CryptoKey;
  private jwks = new Map<string, JWK>();
  upstreamCalls: RecordedCall[] = [];
  /** Responses consumed in order; the last one repeats. */
  upstream: Upstream[] = [{ status: 200, body: okBody() }];
  /** Holds every upstream call until released, to test requests in flight. */
  gate: Promise<void> | null = null;

  async init() {
    for (const [name, url] of [["apple", APPLE_JWKS], ["google", GOOGLE_JWKS]] as const) {
      const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
      const jwk = await exportJWK(publicKey);
      this.jwks.set(url, { ...jwk, kid: `${name}-1`, alg: "RS256", use: "sig" });
      if (name === "apple") this.appleKey = privateKey;
      else this.googleKey = privateKey;
    }
  }

  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const jwk = this.jwks.get(url);
    if (jwk) return Response.json({ keys: [jwk] });

    if (url === `${UPSTREAM}/v1/messages`) {
      this.upstreamCalls.push({
        url,
        headers: new Headers(init?.headers),
        body: JSON.parse(String(init?.body)),
      });
      if (this.gate) await this.gate;
      const index = Math.min(this.upstreamCalls.length - 1, this.upstream.length - 1);
      const next = this.upstream[index]!;
      return new Response(JSON.stringify(next.body), {
        status: next.status,
        headers: { "content-type": "application/json", ...next.headers },
      });
    }
    return new Response("unexpected request to " + url, { status: 599 });
  };
}

export interface TestApp {
  net: FakeNet;
  env: Env;
  clock: { now: number };
  call: (method: string, path: string, opts?: { body?: unknown; token?: string; raw?: string }) => Promise<{ status: number; json: any; headers: Headers; text: string }>;
  signInApple: (sub?: string, extra?: Record<string, unknown>) => Promise<SignedIn>;
  signInGoogle: (sub?: string) => Promise<SignedIn>;
}

export interface SignedIn {
  accessToken: string;
  refreshToken: string;
  userId: string;
}

export async function migrate() {
  await applyD1Migrations(workerEnv.DB, workerEnv.TEST_MIGRATIONS);
}

export async function resetDatabase() {
  for (const table of ["ledger", "subscriptions", "refresh_tokens", "users"]) {
    await workerEnv.DB.prepare(`DELETE FROM ${table}`).run();
  }
}

export async function makeApp(overrides: Partial<Env> = {}): Promise<TestApp> {
  const net = new FakeNet();
  await net.init();
  const clock = { now: START };
  const env: Env = {
    DB: workerEnv.DB,
    ANTHROPIC_API_KEY: API_KEY,
    SESSION_SECRET: "test-session-secret-test-session-secret-0123456789",
    APPLE_AUDIENCE: "com.catchmeup.app",
    APPLE_ISSUER: "https://appleid.apple.com",
    APPLE_JWKS_URL: APPLE_JWKS,
    GOOGLE_AUDIENCE: "google-client-id.apps.googleusercontent.com",
    GOOGLE_ISSUERS: "https://accounts.google.com,accounts.google.com",
    GOOGLE_JWKS_URL: GOOGLE_JWKS,
    ANTHROPIC_BASE_URL: UPSTREAM,
    RECAP_MODEL: "claude-sonnet-5-5",
    RECAP_EFFORT: "medium",
    GLOBAL_DAILY_BUDGET_USD: "25",
    MAX_INPUT_CHARS: "150000",
    MAX_OUTPUT_TOKENS: "16000",
    RATE_LIMIT_PER_MINUTE: "10",
    ...overrides,
  };
  const handler = makeHandler({ fetch: net.fetch, now: () => clock.now, sleep: async () => {} });

  const call: TestApp["call"] = async (method, path, opts = {}) => {
    const headers: Record<string, string> = {};
    if (opts.token) headers.authorization = `Bearer ${opts.token}`;
    const hasBody = opts.raw !== undefined || opts.body !== undefined;
    if (hasBody) headers["content-type"] = "application/json";
    const request = new Request(`https://api.test${path}`, {
      method,
      headers,
      body: hasBody ? (opts.raw ?? JSON.stringify(opts.body)) : undefined,
    });
    const response = await handler.fetch!(request as any, env, createExecutionContext());
    const text = await response.text();
    let parsed: any = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      /* not JSON */
    }
    return { status: response.status, json: parsed, headers: response.headers, text };
  };

  const idToken = async (key: CryptoKey, claims: { iss: string; aud: string; sub: string; nonce?: string; email?: string }, expOffset = 600) => {
    const iat = Math.floor(clock.now / 1000);
    return new SignJWT({ nonce: claims.nonce, email: claims.email })
      .setProtectedHeader({ alg: "RS256", kid: claims.iss.includes("apple") ? "apple-1" : "google-1" })
      .setIssuer(claims.iss)
      .setAudience(claims.aud)
      .setSubject(claims.sub)
      .setIssuedAt(iat)
      .setExpirationTime(iat + expOffset)
      .sign(key);
  };

  const finish = async (path: string, token: string, nonce: string): Promise<SignedIn> => {
    const res = await call("POST", path, { body: { idToken: token, nonce } });
    if (res.status !== 200) throw new Error(`sign-in failed: ${res.status} ${res.text}`);
    return { accessToken: res.json.accessToken, refreshToken: res.json.refreshToken, userId: res.json.user.id };
  };

  return {
    net,
    env,
    clock,
    call,
    signInApple: async (sub = "apple-user-1", extra = {}) => {
      const nonce = "nonce-" + sub;
      const token = await idToken(net.appleKey, {
        iss: "https://appleid.apple.com",
        aud: env.APPLE_AUDIENCE,
        sub,
        nonce,
        email: "student@example.com",
        ...extra,
      });
      return finish("/v1/auth/apple", token, nonce);
    },
    signInGoogle: async (sub = "google-user-1") => {
      const nonce = "nonce-" + sub;
      const token = await idToken(net.googleKey, {
        iss: "https://accounts.google.com",
        aud: env.GOOGLE_AUDIENCE,
        sub,
        nonce,
        email: "g@example.com",
      });
      return finish("/v1/auth/google", token, nonce);
    },
  };
}

/** Exposed so tests can mint tokens that are wrong in specific ways. */
export async function makeIdToken(
  key: CryptoKey,
  claims: { iss: string; aud: string; sub: string; nonce?: string },
  now: number,
  expOffset = 600,
  kid = "apple-1",
) {
  const iat = Math.floor(now / 1000);
  return new SignJWT({ nonce: claims.nonce })
    .setProtectedHeader({ alg: "RS256", kid })
    .setIssuer(claims.iss)
    .setAudience(claims.aud)
    .setSubject(claims.sub)
    .setIssuedAt(iat)
    .setExpirationTime(iat + expOffset)
    .sign(key);
}

export const db = () => workerEnv.DB;

export async function ledgerRows() {
  const { results } = await workerEnv.DB.prepare("SELECT * FROM ledger ORDER BY created_at, id").all<Record<string, any>>();
  return results;
}

export async function grantPlus(userId: string, expiresAt: number) {
  await workerEnv.DB
    .prepare("INSERT INTO subscriptions (user_id, product_id, original_transaction_id, status, expires_at, updated_at) VALUES (?1, 'plus.monthly', ?2, 'active', ?3, ?4)")
    .bind(userId, "otx-" + userId, expiresAt, START)
    .run();
}

export const RECAP_BODY = { task: "recap", system: "s", user: "u", maxTokens: 4096 };
