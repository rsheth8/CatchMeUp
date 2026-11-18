// A local CatchMeUp Cloud for pointing the iOS simulator at. Nothing here is real:
// the model is a stub (no key, no cost) and Apple's key server is faked.
//
//   npm run dev:harness
//
// Prints two addresses. The worker is the API the app talks to. The dev-token
// address mints a fresh signed-in-able Apple token plus a server nonce for each
// GET, which is what the app's DEBUG-only `-hostedDevSignIn <url>` launch
// argument fetches in place of the real Sign in with Apple sheet.
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { chmodSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = 8787;
const FAKE_PORT = 8788;
const STATE = join(root, ".wrangler", "harness-state");
const DEV_VARS = join(root, ".dev.vars");
const base = `http://127.0.0.1:${PORT}`;
const wrangler = join(root, "node_modules", ".bin", "wrangler");

const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
const jwks = { keys: [{ ...(await exportJWK(publicKey)), kid: "apple-1", alg: "RS256", use: "sig" }] };
let userCounter = 0;
const modelCalls = [];

const fake = createServer(async (req, res) => {
  const send = (status, body) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
  if (req.method === "GET" && req.url === "/jwks/apple") return send(200, jwks);
  if (req.method === "GET" && req.url?.startsWith("/dev/token")) {
    // ?user=name keeps the same account across runs; no name makes a new one.
    const name = new URL(req.url, "http://x").searchParams.get("user") || `harness-user-${Date.now()}-${userCounter++}`;
    const nonce = (await (await fetch(`${base}/v1/auth/nonce`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).json()).nonce;
    const iat = Math.floor(Date.now() / 1000);
    const idToken = await new SignJWT({ nonce, email: "student@example.com" })
      .setProtectedHeader({ alg: "RS256", kid: "apple-1" })
      .setIssuer("https://appleid.apple.com").setAudience("com.catchmeup.app").setSubject(name)
      .setIssuedAt(iat).setExpirationTime(iat + 600).sign(privateKey);
    return send(200, { idToken, nonce, provider: "apple" });
  }
  if (req.method === "POST" && req.url === "/v1/messages") {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const parsed = JSON.parse(data);
      modelCalls.push(parsed.model);
      console.log(`model call #${modelCalls.length}: ${parsed.model}`);
      // One reply that decodes as either kind of notes.
      const text = JSON.stringify({
        title: "Stub recap from the local harness",
        tldr: ["This text came from the stubbed model, through the real Worker."],
        keyPoints: [], actionItems: [], decisions: [], openQuestions: [],
        actions: [], outcomes: [], context: [],
      });
      send(200, { stop_reason: "end_turn", content: [{ type: "text", text }], usage: { input_tokens: 1200, output_tokens: 300 } });
    });
    return;
  }
  send(404, {});
});
await new Promise((r) => fake.listen(FAKE_PORT, "127.0.0.1", r));

rmSync(STATE, { recursive: true, force: true });
writeFileSync(DEV_VARS, "ANTHROPIC_API_KEY=sk-harness-not-a-real-key\nSESSION_SECRET=harness-session-secret-harness-session-secret-01\n");
chmodSync(DEV_VARS, 0o600);
const env = { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" };
delete env.ANTHROPIC_API_KEY;

let dev;
const cleanup = () => {
  try { if (dev?.pid) process.kill(-dev.pid, "SIGTERM"); } catch {}
  try { rmSync(DEV_VARS, { force: true }); } catch {}
  fake.close();
};
process.on("exit", cleanup);
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { cleanup(); process.exit(0); });

const migrated = spawnSync(wrangler, ["d1", "migrations", "apply", "catchmeup", "--local", "--persist-to", STATE], { cwd: root, env, encoding: "utf8" });
if (migrated.status !== 0) { console.error(migrated.stderr.slice(0, 600)); process.exit(1); }

dev = spawn(wrangler, [
  "dev", "--local", "--ip", "127.0.0.1", "--port", String(PORT), "--persist-to", STATE,
  "--var", `APPLE_JWKS_URL:http://127.0.0.1:${FAKE_PORT}/jwks/apple`,
  "--var", `ANTHROPIC_BASE_URL:http://127.0.0.1:${FAKE_PORT}`,
], { cwd: root, env, detached: true, stdio: "ignore" });

for (let i = 0; i < 120; i++) {
  try { if ((await fetch(`${base}/health`)).ok) break; } catch {}
  await new Promise((r) => setTimeout(r, 500));
}
console.log(`worker:     ${base}`);
console.log(`dev-token:  http://127.0.0.1:${FAKE_PORT}/dev/token   (add ?user=name to reuse an account)`);
console.log("ready. Ctrl-C to stop.");
setInterval(() => {}, 1 << 30);
