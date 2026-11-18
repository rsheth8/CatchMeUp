// End-to-end check against a real local Worker (wrangler dev, workerd, local D1).
//
//   npm run e2e                                  # model stubbed locally, no key, no cost
//   ANTHROPIC_API_KEY="$(secret get ANTHROPIC_API_KEY)" npm run e2e -- --live
//                                                # one real call to Anthropic through the Worker
//
// Apple and Google key servers are always faked (the script mints its own
// signing keys), so no real accounts are involved. The key, if given, goes
// into a 0600 .dev.vars for the run and is deleted afterwards. It is never
// printed.
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { chmodSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const live = process.argv.includes("--live");
const PORT = 8799;
const FAKE_PORT = 8791;
const STATE = join(root, ".wrangler", "e2e-state");
const DEV_VARS = join(root, ".dev.vars");
const base = `http://127.0.0.1:${PORT}`;
const wrangler = join(root, "node_modules", ".bin", "wrangler");

let failures = 0;
const check = (ok, label, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? `  (${detail})` : ""}`);
  if (!ok) failures++;
};

if (live && !process.env.ANTHROPIC_API_KEY) {
  console.error("--live needs ANTHROPIC_API_KEY in the environment.");
  process.exit(2);
}

// ---- fake Apple/Google keys and (unless --live) a fake model -----------------
const keys = {};
const jwks = {};
for (const name of ["apple", "google"]) {
  const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
  keys[name] = privateKey;
  jwks[name] = { keys: [{ ...(await exportJWK(publicKey)), kid: `${name}-1`, alg: "RS256", use: "sig" }] };
}
const upstreamSeen = [];
const fake = createServer((req, res) => {
  const send = (status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  if (req.method === "GET" && req.url === "/jwks/apple") return send(200, jwks.apple);
  if (req.method === "GET" && req.url === "/jwks/google") return send(200, jwks.google);
  if (req.method === "POST" && req.url === "/v1/messages") {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const parsed = JSON.parse(data);
      upstreamSeen.push({ headers: req.headers, body: parsed });
      // A prompt starting with SLOW takes a few seconds, to leave time for a client to hang up.
      const delay = parsed.messages?.[0]?.content?.startsWith("SLOW") ? 4000 : 0;
      setTimeout(() => send(200, {
        stop_reason: "end_turn",
        content: [{ type: "text", text: JSON.stringify({ title: "Stub recap", tldr: ["stubbed"] }) }],
        usage: { input_tokens: 1000, output_tokens: 500 },
      }), delay);
    });
    return;
  }
  send(404, {});
});
await new Promise((r) => fake.listen(FAKE_PORT, "127.0.0.1", r));

// ---- local worker -----------------------------------------------------------
rmSync(STATE, { recursive: true, force: true });
const vars = {
  ANTHROPIC_API_KEY: live ? process.env.ANTHROPIC_API_KEY : "sk-e2e-not-a-real-key",
  SESSION_SECRET: "e2e-session-secret-e2e-session-secret-0123456789",
};
writeFileSync(DEV_VARS, Object.entries(vars).map(([k, v]) => `${k}=${v}`).join("\n") + "\n");
chmodSync(DEV_VARS, 0o600);

const env = { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" };
delete env.ANTHROPIC_API_KEY; // wrangler reads .dev.vars; do not leak the key into its environment
const run = (args) => spawnSync(wrangler, args, { cwd: root, env, encoding: "utf8" });

let dev;
const cleanup = () => {
  try { if (dev?.pid) process.kill(-dev.pid, "SIGTERM"); } catch {}
  try { rmSync(DEV_VARS, { force: true }); } catch {}
  fake.close();
};
process.on("exit", cleanup);
process.on("SIGINT", () => { cleanup(); process.exit(130); });

const migrated = run(["d1", "migrations", "apply", "catchmeup", "--local", "--persist-to", STATE]);
check(migrated.status === 0, "local database migrated", migrated.status === 0 ? "" : migrated.stderr.slice(0, 300));
if (migrated.status !== 0) process.exit(1);

const devArgs = [
  "dev", "--local", "--ip", "127.0.0.1", "--port", String(PORT), "--persist-to", STATE,
  "--var", `APPLE_JWKS_URL:http://127.0.0.1:${FAKE_PORT}/jwks/apple`,
  "--var", `GOOGLE_JWKS_URL:http://127.0.0.1:${FAKE_PORT}/jwks/google`,
  "--var", "GOOGLE_AUDIENCE:e2e-google-client",
];
if (!live) devArgs.push("--var", `ANTHROPIC_BASE_URL:http://127.0.0.1:${FAKE_PORT}`);
dev = spawn(wrangler, devArgs, { cwd: root, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
let devLog = "";
dev.stdout.on("data", (d) => (devLog += d));
dev.stderr.on("data", (d) => (devLog += d));

for (let i = 0; i < 120; i++) {
  try { if ((await fetch(`${base}/health`)).ok) break; } catch {}
  await new Promise((r) => setTimeout(r, 500));
  if (i === 119) { console.error("worker did not start:\n" + devLog.slice(-1500)); process.exit(1); }
}

// ---- helpers ----------------------------------------------------------------
const call = async (method, path, { body, token } = {}) => {
  const res = await fetch(base + path, {
    method,
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch {}
  return { status: res.status, json, text };
};
const idToken = async (name, claims) => {
  const iat = Math.floor(Date.now() / 1000);
  return new SignJWT({ nonce: claims.nonce, email: "student@example.com" })
    .setProtectedHeader({ alg: "RS256", kid: `${name}-1` })
    .setIssuer(claims.iss).setAudience(claims.aud).setSubject(claims.sub)
    .setIssuedAt(iat).setExpirationTime(iat + 600)
    .sign(keys[name]);
};
const appleToken = (nonce, overrides = {}) =>
  idToken("apple", { iss: "https://appleid.apple.com", aud: "com.catchmeup.app", sub: "e2e-user", nonce, ...overrides });
const serverNonce = async () => (await call("POST", "/v1/auth/nonce", { body: {} })).json?.nonce;
const d1 = (sql) => {
  const r = run(["d1", "execute", "catchmeup", "--local", "--persist-to", STATE, "--json", "--command", sql]);
  try { return JSON.parse(r.stdout)[0].results; } catch { return []; }
};

// ---- the scenario -----------------------------------------------------------
console.log(`\nMode: ${live ? "LIVE (real Anthropic call)" : "stubbed model"}\n`);

check((await call("GET", "/health")).json?.ok === true, "health check");

const nonce = await serverNonce();
check(typeof nonce === "string" && nonce.split(".").length === 3, "server issues a signed sign-in nonce");

const forged = await call("POST", "/v1/auth/apple", { body: { idToken: await appleToken(nonce, { aud: "com.someone.else" }), nonce } });
check(forged.status === 401, "token for another app is rejected", `status ${forged.status}`);

const invented = "client-invented-nonce-0001";
const inventedRes = await call("POST", "/v1/auth/apple", { body: { idToken: await appleToken(invented), nonce: invented } });
check(inventedRes.status === 401, "a nonce the server did not issue is rejected", `status ${inventedRes.status}`);

const signInBody = { idToken: await appleToken(nonce), nonce };
const signedIn = await call("POST", "/v1/auth/apple", { body: signInBody });
check(signedIn.status === 200 && !!signedIn.json?.accessToken, "valid Apple sign-in (the rejected attempts did not burn the nonce)", `status ${signedIn.status}`);
const replay = await call("POST", "/v1/auth/apple", { body: signInBody });
check(replay.status === 401, "replaying the same sign-in is rejected", `status ${replay.status}`);
const token = signedIn.json?.accessToken;

let me = await call("GET", "/v1/me", { token });
check(me.json?.quota?.plan === "free" && me.json?.quota?.recapsRemaining === 3, "new user is free with 3 recaps", JSON.stringify(me.json?.quota));

const transcript = live
  ? readFileSync(join(root, "..", "ios", "Bench", "corpus", "meeting-standup", "transcript.txt"), "utf8")
  : "[00:00:01] Speaker 1: Ship the fix on Thursday.";
const recapBody = {
  task: "recap",
  system: 'You write meeting notes. Reply with only JSON: {"title": string, "tldr": string[]}.',
  user: transcript,
  maxTokens: 4096,
};

const remaining = [];
for (let i = 1; i <= 3; i++) {
  const t0 = Date.now();
  const r = await call("POST", "/v1/recap", { token, body: { ...recapBody, jobId: `e2e-recording-${i}` } });
  remaining.push(r.json?.quota?.recapsRemaining);
  let parses = true;
  try { JSON.parse(r.json.text.replace(/^```(?:json)?\s*|\s*```$/g, "")); } catch { parses = false; }
  check(r.status === 200 && parses, `recap ${i} of 3 succeeds`, `status ${r.status}, ${((Date.now() - t0) / 1000).toFixed(1)}s, ${r.json?.quota?.recapsRemaining} left`);
  if (live && i === 1) break; // one real call is enough evidence; do not spend more
}

if (!live) {
  check(JSON.stringify(remaining) === "[2,1,0]", "quota counts down 2, 1, 0", JSON.stringify(remaining));
  const fourth = await call("POST", "/v1/recap", { token, body: { ...recapBody, jobId: "e2e-recording-4" } });
  check(fourth.status === 402 && fourth.json?.error?.code === "quota_exceeded", "4th recap refused with 402 quota_exceeded", `status ${fourth.status}`);
  check(upstreamSeen.length === 3, "the refused request never reached the model", `${upstreamSeen.length} model calls`);

  const seen = upstreamSeen[0];
  check(seen.body.model === "claude-haiku-5-5" && seen.body.temperature === undefined && seen.body.output_config?.effort === "medium", "free plan uses Haiku, server-chosen effort, no sampling params");
  check(seen.headers["x-api-key"] === "sk-e2e-not-a-real-key", "API key is sent to the model provider as a header");

  d1(`INSERT INTO subscriptions (user_id, product_id, status, expires_at, updated_at) VALUES ('${signedIn.json.user.id}', 'plus.monthly', 'active', ${Date.now() + 86_400_000}, ${Date.now()})`);
  const plus = await call("POST", "/v1/recap", { token, body: { ...recapBody, jobId: "e2e-recording-4" } });
  check(plus.status === 200 && plus.json?.quota?.plan === "plus", "an active subscription lifts the limit", `plan ${plus.json?.quota?.plan}, ${plus.json?.quota?.recapsRemaining} left`);
  check(upstreamSeen[3]?.body.model === "claude-sonnet-5-5", "an active subscription switches the call to Sonnet", upstreamSeen[3]?.body.model);
}

if (!live) {
  // A phone that loses signal mid-recap must not leave an unmetered model call behind.
  const hangUp = new AbortController();
  const slow = fetch(`${base}/v1/recap`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ ...recapBody, jobId: "e2e-recording-5", user: "SLOW " + transcript }),
    signal: hangUp.signal,
  }).catch(() => null);
  await new Promise((r) => setTimeout(r, 700));
  hangUp.abort();
  await slow;
  await new Promise((r) => setTimeout(r, 6000));
  const [last] = d1("SELECT status, cost_micro FROM ledger ORDER BY created_at DESC LIMIT 1");
  check(last?.status === "settled" && last.cost_micro > 0, "a client that hangs up mid-request is still fully metered", JSON.stringify(last));
}

const ledger = d1("SELECT status, model, cost_micro, input_tokens, output_tokens FROM ledger ORDER BY created_at");
console.log("\nLedger rows:", JSON.stringify(ledger));
check(ledger.length > 0 && ledger.every((r) => r.status === "settled" && r.cost_micro > 0), "every call is metered in the ledger");

const del = await call("DELETE", "/v1/me", { token });
check(del.status === 200, "account deletion");
check((await call("GET", "/v1/me", { token })).status === 401, "deleted account's token stops working immediately");

const logsClean = !devLog.includes(vars.ANTHROPIC_API_KEY) && !devLog.includes(transcript.slice(0, 40)) && !devLog.includes(token);
check(logsClean, "worker logs contain no API key, token or transcript text");

console.log(`\n${failures === 0 ? "All checks passed." : failures + " check(s) failed."}`);
process.exit(failures === 0 ? 0 : 1);
