import { jwtVerify, SignJWT } from "jose";
import { randomToken, sha256Hex } from "./crypto";
import type { Env } from "./env";
import { ApiError } from "./http";

export const ACCESS_TTL_SECONDS = 60 * 60;
export const REFRESH_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const ISSUER = "catchmeup-api";
const AUDIENCE = "catchmeup-app";

function secretKey(env: Env): Uint8Array {
  if (!env.SESSION_SECRET || env.SESSION_SECRET.length < 32) {
    throw new ApiError(500, "misconfigured", "The service is not configured correctly.", { setting: "SESSION_SECRET" });
  }
  return new TextEncoder().encode(env.SESSION_SECRET);
}

/** Short-lived access token. The refresh token is what keeps someone signed in. */
export async function issueAccessToken(env: Env, userId: string, nowMs: number): Promise<{ token: string; expiresIn: number }> {
  const iat = Math.floor(nowMs / 1000);
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt(iat)
    .setExpirationTime(iat + ACCESS_TTL_SECONDS)
    .sign(secretKey(env));
  return { token, expiresIn: ACCESS_TTL_SECONDS };
}

export async function verifyAccessToken(env: Env, token: string, nowMs: number): Promise<string> {
  try {
    const { payload } = await jwtVerify(token, secretKey(env), {
      issuer: ISSUER,
      audience: AUDIENCE,
      algorithms: ["HS256"],
      currentDate: new Date(nowMs),
    });
    if (typeof payload.sub !== "string") throw new Error("no subject");
    return payload.sub;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(401, "unauthorized", "Sign in again to continue.");
  }
}

export async function createRefreshToken(db: D1Database, userId: string, nowMs: number): Promise<string> {
  const token = randomToken(32);
  await db
    .prepare("INSERT INTO refresh_tokens (token_hash, user_id, created_at, expires_at) VALUES (?1, ?2, ?3, ?4)")
    .bind(await sha256Hex(token), userId, nowMs, nowMs + REFRESH_TTL_MS)
    .run();
  return token;
}

/**
 * Exchanges a refresh token for its user and slides its expiry forward.
 * Not rotated on purpose: a phone that retries after a dropped connection
 * must never be locked out by its own retry.
 */
export async function useRefreshToken(db: D1Database, token: string, nowMs: number): Promise<string> {
  const hash = await sha256Hex(token);
  const row = await db
    .prepare(
      `SELECT r.user_id AS userId FROM refresh_tokens r
       JOIN users u ON u.id = r.user_id
       WHERE r.token_hash = ?1 AND r.revoked_at IS NULL AND r.expires_at > ?2 AND u.deleted_at IS NULL`,
    )
    .bind(hash, nowMs)
    .first<{ userId: string }>();
  if (!row) throw new ApiError(401, "unauthorized", "Sign in again to continue.");
  await db
    .prepare("UPDATE refresh_tokens SET last_used_at = ?2, expires_at = ?3 WHERE token_hash = ?1")
    .bind(hash, nowMs, nowMs + REFRESH_TTL_MS)
    .run();
  return row.userId;
}

export async function revokeRefreshToken(db: D1Database, token: string, nowMs: number): Promise<void> {
  await db
    .prepare("UPDATE refresh_tokens SET revoked_at = ?2 WHERE token_hash = ?1 AND revoked_at IS NULL")
    .bind(await sha256Hex(token), nowMs)
    .run();
}

export async function revokeAllRefreshTokens(db: D1Database, userId: string, nowMs: number): Promise<void> {
  await db
    .prepare("UPDATE refresh_tokens SET revoked_at = ?2 WHERE user_id = ?1 AND revoked_at IS NULL")
    .bind(userId, nowMs)
    .run();
}
