import type { Ctx } from "./context";
import { defaultDeps, type Deps, type Env } from "./env";
import { ApiError, errorResponse, json, log } from "./http";
import { makeVerifier } from "./idtoken";
import { logout, refresh, signIn } from "./routes/auth";
import { deleteMe, getMe } from "./routes/me";
import { recap } from "./routes/recap";

type Handler = (request: Request, ctx: Ctx) => Promise<Response>;

const ROUTES: Record<string, Handler> = {
  "POST /v1/auth/apple": (r, c) => signIn("apple", r, c),
  "POST /v1/auth/google": (r, c) => signIn("google", r, c),
  "POST /v1/auth/refresh": refresh,
  "POST /v1/auth/logout": logout,
  "GET /v1/me": getMe,
  "DELETE /v1/me": deleteMe,
  "POST /v1/recap": recap,
};

/**
 * Builds the request handler. Dependencies (network, clock, sleep) are
 * injectable so tests can run the whole stack with no outside calls.
 */
export function makeHandler(overrides: Partial<Deps> = {}): ExportedHandler<Env> {
  const deps: Deps = { ...defaultDeps, ...overrides };
  const verifiers = new WeakMap<Env, ReturnType<typeof makeVerifier>>();

  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      const requestId = request.headers.get("cf-ray") ?? crypto.randomUUID();
      try {
        if (url.pathname === "/health") return json({ ok: true });

        const handler = ROUTES[`${request.method} ${url.pathname}`];
        if (!handler) {
          const known = Object.keys(ROUTES).some((key) => key.endsWith(` ${url.pathname}`));
          throw known
            ? new ApiError(405, "method_not_allowed", "That method is not allowed here.")
            : new ApiError(404, "not_found", "Not found.");
        }

        let verifier = verifiers.get(env);
        if (!verifier) {
          verifier = makeVerifier(env, deps);
          verifiers.set(env, verifier);
        }
        return await handler(request, { env, deps, verifier, now: deps.now(), requestId });
      } catch (error) {
        if (error instanceof ApiError) return errorResponse(error);
        // Anything else is a bug. Log the type only: messages can carry user text.
        log("unhandled_error", { name: error instanceof Error ? error.name : "unknown", requestId });
        return errorResponse(new ApiError(500, "internal_error", "Something went wrong on our side."));
      }
    },
  };
}

export default makeHandler();
