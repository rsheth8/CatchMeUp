import { requireUser, type Ctx } from "../context";
import { json } from "../http";
import { deleteUser, planFor, quotaFor } from "../users";

export async function getMe(request: Request, ctx: Ctx): Promise<Response> {
  const user = await requireUser(request, ctx);
  const plan = await planFor(ctx.env.DB, user.id, ctx.now);
  return json({
    user: { id: user.id, email: user.email },
    quota: await quotaFor(ctx.env.DB, user.id, plan, ctx.now),
  });
}

/**
 * Deletes the account (an App Store requirement for apps with sign-in).
 * A subscription is billed by Apple, so it keeps running until the person
 * cancels it in their App Store settings; the response says so.
 */
export async function deleteMe(request: Request, ctx: Ctx): Promise<Response> {
  const user = await requireUser(request, ctx);
  const plan = await planFor(ctx.env.DB, user.id, ctx.now);
  await deleteUser(ctx.env.DB, user.id, ctx.now);
  return json({ deleted: true, subscriptionStillActive: plan.id === "plus" });
}
