import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { db, makeApp, makeIdToken, migrate, resetDatabase } from "./helpers";

beforeAll(migrate);
beforeEach(resetDatabase);

const APPLE = "https://appleid.apple.com";

describe("sign in", () => {
  it("accepts a valid Apple token and returns a session", async () => {
    const app = await makeApp();
    const res = await app.call("POST", "/v1/auth/apple", { body: await body(app, {}) });
    expect(res.status).toBe(200);
    expect(res.json.accessToken).toBeTruthy();
    expect(res.json.refreshToken).toBeTruthy();
    expect(res.json.expiresIn).toBe(3600);
    expect(res.json.user.email).toBeNull(); // this token carries no email claim

    const withEmail = await app.signInApple("has-email");
    const me = await app.call("GET", "/v1/me", { token: withEmail.accessToken });
    expect(me.json.user.email).toBe("student@example.com");
  });

  it("accepts a valid Google token", async () => {
    const app = await makeApp();
    const session = await app.signInGoogle();
    const me = await app.call("GET", "/v1/me", { token: session.accessToken });
    expect(me.status).toBe(200);
    expect(me.json.user.email).toBe("g@example.com");
  });

  it("accepts a nonce sent either raw or as its SHA-256 hex", async () => {
    const app = await makeApp();
    const raw = "raw-nonce-123";
    const hashed = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw)))]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    for (const claim of [raw, hashed]) {
      const token = await makeIdToken(app.net.appleKey, { iss: APPLE, aud: app.env.APPLE_AUDIENCE, sub: "n-user", nonce: claim }, app.clock.now);
      const res = await app.call("POST", "/v1/auth/apple", { body: { idToken: token, nonce: raw } });
      expect(res.status).toBe(200);
    }
  });

  it.each([
    ["wrong audience", { aud: "com.someone.else" }],
    ["wrong issuer", { iss: "https://evil.example" }],
    ["nonce that does not match", { nonce: "a-different-nonce" }],
  ])("rejects a token with a %s", async (_name, claims) => {
    const app = await makeApp();
    const res = await app.call("POST", "/v1/auth/apple", { body: await body(app, claims) });
    expect(res.status).toBe(401);
    expect(res.json.error.code).toBe("invalid_token");
  });

  it("rejects a token with no nonce claim", async () => {
    const app = await makeApp();
    const token = await makeIdToken(app.net.appleKey, { iss: APPLE, aud: app.env.APPLE_AUDIENCE, sub: "x" }, app.clock.now);
    const res = await app.call("POST", "/v1/auth/apple", { body: { idToken: token, nonce: "nonce-12345" } });
    expect(res.status).toBe(401);
  });

  it("rejects an expired token", async () => {
    const app = await makeApp();
    const token = await makeIdToken(app.net.appleKey, { iss: APPLE, aud: app.env.APPLE_AUDIENCE, sub: "x", nonce: "nonce-12345" }, app.clock.now - 3_600_000, 600);
    const res = await app.call("POST", "/v1/auth/apple", { body: { idToken: token, nonce: "nonce-12345" } });
    expect(res.status).toBe(401);
  });

  it("rejects a token signed with some other key", async () => {
    const app = await makeApp();
    // Google's key claiming to be Apple.
    const token = await makeIdToken(app.net.googleKey, { iss: APPLE, aud: app.env.APPLE_AUDIENCE, sub: "x", nonce: "nonce-12345" }, app.clock.now);
    const res = await app.call("POST", "/v1/auth/apple", { body: { idToken: token, nonce: "nonce-12345" } });
    expect(res.status).toBe(401);
  });

  it("does not take an Apple token at the Google endpoint", async () => {
    const app = await makeApp();
    const res = await app.call("POST", "/v1/auth/google", { body: await body(app, {}) });
    expect(res.status).toBe(401);
  });

  it("is unavailable, not open, when the provider is not configured", async () => {
    const app = await makeApp({ GOOGLE_AUDIENCE: "" });
    const token = await makeIdToken(app.net.googleKey, { iss: "https://accounts.google.com", aud: "", sub: "x", nonce: "nonce-12345" }, app.clock.now, 600, "google-1");
    const res = await app.call("POST", "/v1/auth/google", { body: { idToken: token, nonce: "nonce-12345" } });
    expect(res.status).toBe(503);
    expect(res.json.error.code).toBe("provider_unavailable");
  });

  it.each([
    ["no body fields", {}],
    ["a short nonce", { idToken: "x", nonce: "short" }],
    ["a non-string token", { idToken: 5, nonce: "nonce-12345" }],
  ])("returns 400 for %s", async (_name, payload) => {
    const app = await makeApp();
    const res = await app.call("POST", "/v1/auth/apple", { body: payload });
    expect(res.status).toBe(400);
  });

  it("gives the same user back on every sign in, and never stores the provider's subject", async () => {
    const app = await makeApp();
    const first = await app.signInApple("the-apple-sub");
    const second = await app.signInApple("the-apple-sub");
    expect(second.userId).toBe(first.userId);

    const { results } = await db().prepare("SELECT * FROM users").all<Record<string, unknown>>();
    expect(results).toHaveLength(1);
    expect(JSON.stringify(results)).not.toContain("the-apple-sub");
  });

  it("keeps Apple and Google identities as separate users", async () => {
    const app = await makeApp();
    const a = await app.signInApple("same-sub");
    const g = await app.signInGoogle("same-sub");
    expect(a.userId).not.toBe(g.userId);
  });
});

describe("sessions", () => {
  it("rejects calls with no token, a malformed one, or a forged one", async () => {
    const app = await makeApp();
    expect((await app.call("GET", "/v1/me")).status).toBe(401);
    expect((await app.call("GET", "/v1/me", { token: "not-a-jwt" })).status).toBe(401);

    const other = await makeApp({ SESSION_SECRET: "a-completely-different-secret-value-0123456789" });
    const forged = await other.signInApple("forger");
    expect((await app.call("GET", "/v1/me", { token: forged.accessToken })).status).toBe(401);
  });

  it("expires access tokens after an hour and lets the refresh token renew them", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    app.clock.now += 61 * 60 * 1000;
    expect((await app.call("GET", "/v1/me", { token: session.accessToken })).status).toBe(401);

    const renewed = await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } });
    expect(renewed.status).toBe(200);
    expect((await app.call("GET", "/v1/me", { token: renewed.json.accessToken })).status).toBe(200);
  });

  it("lets a refresh token be used repeatedly, so a retried request cannot lock anyone out", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    for (let i = 0; i < 3; i++) {
      const res = await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } });
      expect(res.status).toBe(200);
    }
  });

  it("slides the refresh token's expiry forward, then lets it lapse after 90 idle days", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    app.clock.now += 80 * 24 * 3600 * 1000;
    expect((await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } })).status).toBe(200);
    app.clock.now += 80 * 24 * 3600 * 1000;
    expect((await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } })).status).toBe(200);
    app.clock.now += 91 * 24 * 3600 * 1000;
    expect((await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } })).status).toBe(401);
  });

  it("stores only a hash of the refresh token", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    const { results } = await db().prepare("SELECT * FROM refresh_tokens").all();
    expect(JSON.stringify(results)).not.toContain(session.refreshToken);
  });

  it("revokes a refresh token on logout", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    expect((await app.call("POST", "/v1/auth/logout", { body: { refreshToken: session.refreshToken } })).status).toBe(200);
    expect((await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } })).status).toBe(401);
  });

  it("refuses an unknown refresh token", async () => {
    const app = await makeApp();
    expect((await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: "nope" } })).status).toBe(401);
  });

  it("refuses to run with a short or missing session secret", async () => {
    const app = await makeApp({ SESSION_SECRET: "short" });
    const res = await app.call("POST", "/v1/auth/apple", { body: await body(app, {}) });
    expect(res.status).toBe(500);
    expect(res.json.error.code).toBe("misconfigured");
  });
});

describe("account deletion", () => {
  it("ends the session at once, drops the email, and revokes refresh tokens", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    const res = await app.call("DELETE", "/v1/me", { token: session.accessToken });
    expect(res.status).toBe(200);
    expect(res.json.deleted).toBe(true);

    // The access token is still inside its hour, but the account is gone.
    expect((await app.call("GET", "/v1/me", { token: session.accessToken })).status).toBe(401);
    expect((await app.call("POST", "/v1/auth/refresh", { body: { refreshToken: session.refreshToken } })).status).toBe(401);
    const row = await db().prepare("SELECT email, deleted_at FROM users WHERE id = ?1").bind(session.userId).first<any>();
    expect(row.email).toBeNull();
    expect(row.deleted_at).not.toBeNull();
  });

  it("brings the same account back on sign in, so deleting cannot reset a free quota", async () => {
    const app = await makeApp();
    const first = await app.signInApple("repeat-user");
    await app.call("DELETE", "/v1/me", { token: first.accessToken });
    const again = await app.signInApple("repeat-user");
    expect(again.userId).toBe(first.userId);
    expect((await app.call("GET", "/v1/me", { token: again.accessToken })).status).toBe(200);
  });

  it("says when a subscription is still running, since only Apple can cancel it", async () => {
    const app = await makeApp();
    const session = await app.signInApple();
    await db()
      .prepare("INSERT INTO subscriptions (user_id, product_id, status, expires_at, updated_at) VALUES (?1, 'p', 'active', ?2, ?3)")
      .bind(session.userId, app.clock.now + 86_400_000, app.clock.now)
      .run();
    const res = await app.call("DELETE", "/v1/me", { token: session.accessToken });
    expect(res.json.subscriptionStillActive).toBe(true);
  });
});

async function body(app: Awaited<ReturnType<typeof makeApp>>, claims: Record<string, unknown>) {
  const nonce = "nonce-12345";
  const token = await makeIdToken(
    app.net.appleKey,
    { iss: APPLE, aud: app.env.APPLE_AUDIENCE, sub: "apple-user", nonce, ...claims } as any,
    app.clock.now,
  );
  return { idToken: token, nonce };
}
