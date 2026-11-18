import { randomToken, sha256Hex } from "./crypto";
import type { Env } from "./env";
import { ApiError } from "./http";

/**
 * Sign-in nonces are chosen by the server, not the app. The app asks for one,
 * puts it in the Apple or Google sign-in request, and sends it back with the
 * resulting identity token. The server accepts a nonce only if it issued it,
 * it has not expired, and it has not been used before, so a captured identity
 * token cannot be replayed to get a session.
 *
 * A nonce is "<random>.<expiry ms>.<HMAC>". Issuing it needs no database
 * write, so the unauthenticated endpoint cannot be used to fill the database.
 */
export const NONCE_TTL_MS = 10 * 60 * 1000;

async function mac(env: Env, payload: string): Promise<string> {
  if (!env.SESSION_SECRET || env.SESSION_SECRET.length < 32) {
    throw new ApiError(500, "misconfigured", "The service is not configured correctly.", { setting: "SESSION_SECRET" });
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.SESSION_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  // The prefix keeps this MAC from ever being valid for any other use of the secret.
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`catchmeup.nonce.v1.${payload}`));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function issueNonce(env: Env, nowMs: number): Promise<string> {
  const payload = `${randomToken(16)}.${nowMs + NONCE_TTL_MS}`;
  return `${payload}.${await mac(env, payload)}`;
}

const INVALID = () => new ApiError(401, "invalid_token", "That sign-in could not be verified.");

/** Throws unless this server issued the nonce and it is still within its lifetime. */
export async function verifyNonce(env: Env, nonce: string, nowMs: number): Promise<void> {
  const parts = nonce.split(".");
  if (parts.length !== 3) throw INVALID();
  const [random, expiry, signature] = parts as [string, string, string];
  const expected = await mac(env, `${random}.${expiry}`);
  if (signature.length !== expected.length) throw INVALID();
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= signature.charCodeAt(i) ^ expected.charCodeAt(i);
  if (diff !== 0) throw INVALID();
  const expiresAt = Number(expiry);
  if (!Number.isFinite(expiresAt) || expiresAt <= nowMs) throw INVALID();
}

/**
 * Marks a nonce used. Returns false if it was already used. Call this only
 * after the identity token has been verified, so failed attempts do not burn
 * nonces and callers without a valid token cannot write rows.
 */
export async function consumeNonce(db: D1Database, nonce: string, nowMs: number): Promise<boolean> {
  const expiresAt = Number(nonce.split(".")[1]);
  // Rows past their expiry can never match a valid nonce again, so they go.
  await db
    .prepare("DELETE FROM used_nonces WHERE hash IN (SELECT hash FROM used_nonces WHERE expires_at < ?1 LIMIT 100)")
    .bind(nowMs)
    .run();
  const result = await db
    .prepare("INSERT OR IGNORE INTO used_nonces (hash, expires_at) VALUES (?1, ?2)")
    .bind(await sha256Hex(nonce), expiresAt)
    .run();
  return (result.meta.changes ?? 0) === 1;
}
