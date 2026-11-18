import { createRemoteJWKSet, customFetch, jwtVerify, type JWTVerifyGetKey } from "jose";
import { sha256Hex } from "./crypto";
import type { Deps, Env } from "./env";
import { ApiError } from "./http";

export type Provider = "apple" | "google";

export interface Identity {
  provider: Provider;
  subject: string;
  email: string | null;
}

/**
 * Verifies an Apple or Google identity token: signature against the provider's
 * published keys, issuer, audience (this app), expiry, and a nonce the app
 * generated for this sign-in, which stops a captured token being replayed.
 */
export function makeVerifier(env: Env, deps: Deps) {
  const keySets = new Map<string, JWTVerifyGetKey>();
  const keysFor = (url: string): JWTVerifyGetKey => {
    let keys = keySets.get(url);
    if (!keys) {
      keys = createRemoteJWKSet(new URL(url), { [customFetch]: deps.fetch as typeof fetch });
      keySets.set(url, keys);
    }
    return keys;
  };

  return {
    async verify(provider: Provider, idToken: string, nonce: string): Promise<Identity> {
      const audience = provider === "apple" ? env.APPLE_AUDIENCE : env.GOOGLE_AUDIENCE;
      const issuers = (provider === "apple" ? env.APPLE_ISSUER : env.GOOGLE_ISSUERS)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      const jwksUrl = provider === "apple" ? env.APPLE_JWKS_URL : env.GOOGLE_JWKS_URL;
      if (!audience || issuers.length === 0 || !jwksUrl) {
        throw new ApiError(503, "provider_unavailable", `Sign in with ${provider === "apple" ? "Apple" : "Google"} is not available yet.`);
      }

      let payload;
      try {
        ({ payload } = await jwtVerify(idToken, keysFor(jwksUrl), {
          issuer: issuers,
          audience,
          algorithms: ["RS256"],
          clockTolerance: 30,
          currentDate: new Date(deps.now()),
        }));
      } catch {
        throw new ApiError(401, "invalid_token", "That sign-in could not be verified.");
      }

      if (typeof payload.sub !== "string" || !payload.sub) {
        throw new ApiError(401, "invalid_token", "That sign-in could not be verified.");
      }
      // Clients put either the raw nonce or its SHA-256 hex in the request.
      const claim = payload.nonce;
      if (typeof claim !== "string" || (claim !== nonce && claim !== (await sha256Hex(nonce)))) {
        throw new ApiError(401, "invalid_token", "That sign-in could not be verified.");
      }
      return { provider, subject: payload.sub, email: typeof payload.email === "string" ? payload.email : null };
    },
  };
}

export type Verifier = ReturnType<typeof makeVerifier>;
