import { sha256Hex } from "./crypto";
import type { Identity } from "./idtoken";
import { PLANS, recapsRemaining, nextPeriodStart, type Plan } from "./plans";
import { usageFor } from "./ledger";
import { revokeAllRefreshTokens } from "./session";

export interface User {
  id: string;
  provider: string;
  email: string | null;
}

/**
 * Finds or creates the user for a verified identity. The provider's subject is
 * stored only as a hash. A previously deleted account is reactivated, with its
 * usage history intact, so deleting and signing back in cannot reset a quota.
 */
export async function upsertUser(db: D1Database, identity: Identity, nowMs: number): Promise<User> {
  const hash = await sha256Hex(`${identity.provider}:${identity.subject}`);
  const existing = await db
    .prepare("SELECT id, provider, email, deleted_at AS deletedAt FROM users WHERE provider = ?1 AND identity_hash = ?2")
    .bind(identity.provider, hash)
    .first<{ id: string; provider: string; email: string | null; deletedAt: number | null }>();

  if (existing) {
    const email = identity.email ?? existing.email;
    if (existing.deletedAt !== null || email !== existing.email) {
      await db.prepare("UPDATE users SET deleted_at = NULL, email = ?2 WHERE id = ?1").bind(existing.id, email).run();
    }
    return { id: existing.id, provider: existing.provider, email };
  }

  const id = crypto.randomUUID();
  await db
    .prepare("INSERT INTO users (id, provider, identity_hash, email, created_at) VALUES (?1, ?2, ?3, ?4, ?5)")
    .bind(id, identity.provider, hash, identity.email, nowMs)
    .run();
  return { id, provider: identity.provider, email: identity.email };
}

export async function getUser(db: D1Database, id: string): Promise<User | null> {
  return db
    .prepare("SELECT id, provider, email FROM users WHERE id = ?1 AND deleted_at IS NULL")
    .bind(id)
    .first<User>();
}

/** "plus" while a subscription's expiry is in the future, otherwise "free". */
export async function planFor(db: D1Database, userId: string, nowMs: number): Promise<Plan> {
  const row = await db
    .prepare("SELECT 1 AS active FROM subscriptions WHERE user_id = ?1 AND expires_at > ?2")
    .bind(userId, nowMs)
    .first();
  return row ? PLANS.plus : PLANS.free;
}

export async function quotaFor(db: D1Database, userId: string, plan: Plan, nowMs: number) {
  const usage = await usageFor(db, userId, nowMs);
  return {
    plan: plan.id,
    recapsRemaining: recapsRemaining(plan, usage.recaps, usage.spentMicro),
    resetsAt: nextPeriodStart(nowMs),
  };
}

/**
 * Account deletion: drops the email and every session, and marks the account
 * deleted. The hashed identity and ledger rows stay (no personal data, needed
 * for spend accounting and to stop quota resets); see the README.
 */
export async function deleteUser(db: D1Database, userId: string, nowMs: number): Promise<void> {
  await db.prepare("UPDATE users SET email = NULL, deleted_at = ?2 WHERE id = ?1").bind(userId, nowMs).run();
  await revokeAllRefreshTokens(db, userId, nowMs);
}
