import type { Ctx } from "../context";
import { json, readJsonObject, stringField } from "../http";
import type { Provider } from "../idtoken";
import {
  createRefreshToken,
  issueAccessToken,
  revokeRefreshToken,
  useRefreshToken,
} from "../session";
import { consumeNonce, issueNonce, NONCE_TTL_MS, verifyNonce } from "../nonce";
import { getUser, upsertUser } from "../users";
import { ApiError } from "../http";

/** Hands the app a fresh, signed, single-use nonce to put in its sign-in request. */
export async function nonce(_request: Request, ctx: Ctx): Promise<Response> {
  return json({ nonce: await issueNonce(ctx.env, ctx.now), expiresIn: NONCE_TTL_MS / 1000 });
}

/** Sign in with a verified Apple or Google identity token. */
export async function signIn(provider: Provider, request: Request, ctx: Ctx): Promise<Response> {
  const body = await readJsonObject(request, 16_384);
  const idToken = stringField(body, "idToken", { max: 8_192 });
  const nonceValue = stringField(body, "nonce", { min: 8, max: 256 });

  // Cheap checks first: we issued this nonce and it is still fresh. Then the
  // token, which must carry that nonce. Only then is the nonce used up, so a
  // replayed token fails here and a bad token does not burn a good nonce.
  await verifyNonce(ctx.env, nonceValue, ctx.now);
  const identity = await ctx.verifier.verify(provider, idToken, nonceValue);
  if (!(await consumeNonce(ctx.env.DB, nonceValue, ctx.now))) {
    throw new ApiError(401, "invalid_token", "That sign-in could not be verified.");
  }
  const user = await upsertUser(ctx.env.DB, identity, ctx.now);
  const access = await issueAccessToken(ctx.env, user.id, ctx.now);
  const refreshToken = await createRefreshToken(ctx.env.DB, user.id, ctx.now);

  return json({
    accessToken: access.token,
    expiresIn: access.expiresIn,
    refreshToken,
    user: { id: user.id, email: user.email },
  });
}

export async function refresh(request: Request, ctx: Ctx): Promise<Response> {
  const body = await readJsonObject(request, 4_096);
  const refreshToken = stringField(body, "refreshToken", { max: 256 });

  const userId = await useRefreshToken(ctx.env.DB, refreshToken, ctx.now);
  const user = await getUser(ctx.env.DB, userId);
  if (!user) throw new ApiError(401, "unauthorized", "Sign in again to continue.");
  const access = await issueAccessToken(ctx.env, user.id, ctx.now);
  return json({ accessToken: access.token, expiresIn: access.expiresIn });
}

export async function logout(request: Request, ctx: Ctx): Promise<Response> {
  const body = await readJsonObject(request, 4_096);
  const refreshToken = stringField(body, "refreshToken", { max: 256 });
  await revokeRefreshToken(ctx.env.DB, refreshToken, ctx.now);
  return json({ ok: true });
}
