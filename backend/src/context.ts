import type { Deps, Env } from "./env";
import { ApiError } from "./http";
import type { Verifier } from "./idtoken";
import { verifyAccessToken } from "./session";
import { getUser, type User } from "./users";

/** Everything a route needs, built once per request. */
export interface Ctx {
  env: Env;
  deps: Deps;
  verifier: Verifier;
  now: number;
  requestId: string;
}

/** Resolves the signed-in user from the bearer token, or throws 401. */
export async function requireUser(request: Request, ctx: Ctx): Promise<User> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/i.exec(header);
  if (!match || !match[1]) throw new ApiError(401, "unauthorized", "Sign in to continue.");
  const userId = await verifyAccessToken(ctx.env, match[1], ctx.now);
  // Checked on every call, so deleting an account takes effect immediately
  // instead of when its access token expires.
  const user = await getUser(ctx.env.DB, userId);
  if (!user) throw new ApiError(401, "unauthorized", "Sign in again to continue.");
  return user;
}
