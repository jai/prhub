import { invalidatesProviderToken, type PushResult, sendToApns } from "./apns.ts";
import type { Deps, Env } from "./env.ts";
import { bearerToken, constantTimeEqual, newKey, sha256Hex } from "./keys.ts";
import { type CachedJwt, isFreshJwt } from "./stores.ts";
import { BODY_MAX_BYTES, parseKeyBody, parsePushBody } from "./validate.ts";

const INDEX_NAME = "index";

/** The relay's fetch handler (docs/push-relay.md). One per isolate: it memoises the provider token. */
export function createRelay(deps: Deps) {
  let memo: CachedJwt | null = null;

  async function providerToken(env: Env, nowSeconds: number): Promise<CachedJwt | { error: string }> {
    if (env.APNS_KEY_ID && isFreshJwt(memo, env.APNS_KEY_ID, nowSeconds)) return memo;
    const result = await index(env).jwt(nowSeconds);
    if ("token" in result) memo = result;
    return result;
  }

  async function push(request: Request, env: Env): Promise<Response> {
    const key = bearerToken(request);
    if (key === null || !key.startsWith("rks_")) return error(401, "unauthorized");
    const keyStore = env.RELAY_KEY.get(env.RELAY_KEY.idFromName(await sha256Hex(key)));
    const nowSeconds = Math.floor(deps.now() / 1000);

    const text = await readBody(request);
    const parsed = text === null ? ({ ok: false, error: "body_too_large" } as const) : parsePushBody(text);
    // A bad body is still 401 for a bad key, and never counts against a good one.
    const auth = await keyStore.authorize(nowSeconds, parsed.ok);
    if (auth.status === 401) return error(401, "unauthorized");
    if (!parsed.ok) return error(400, parsed.error);
    if (auth.status === 429) return json(429, { error: "rate_limited", retry_after: auth.retry_after });

    const body = parsed.value;
    const jwt = await providerToken(env, nowSeconds);
    let result: PushResult;
    if ("token" in jwt) {
      result = await sendToApns(deps.fetch, jwt.token, { ...body, topic: env.APNS_TOPIC });
      if (invalidatesProviderToken(result)) {
        memo = null;
        await index(env).invalidateJwt(jwt.token);
      }
    } else {
      result = { apns_status: null, apns_id: null, reason: jwt.error };
    }
    console.log(
      JSON.stringify({
        event: "push",
        key_id: auth.key_id,
        apns_env: body.apnsEnv,
        push_type: body.pushType,
        apns_status: result.apns_status,
        reason: result.reason,
      }),
    );
    return json(200, result);
  }

  async function issueKey(request: Request, env: Env): Promise<Response> {
    const text = await readBody(request);
    const parsed = text === null ? ({ ok: false, error: "body_too_large" } as const) : parseKeyBody(text);
    if (!parsed.ok) return error(400, parsed.error);
    const { keyId, key } = newKey();
    const hash = await sha256Hex(key);
    const createdAt = new Date(deps.now()).toISOString();
    // Index first: a failure between the two leaves a listed key that cannot send, never a live key nobody sees.
    await index(env).add({ key_id: keyId, hash, label: parsed.value.label, created_at: createdAt });
    await env.RELAY_KEY.get(env.RELAY_KEY.idFromName(hash)).init({
      key_id: keyId,
      label: parsed.value.label,
      created_at: createdAt,
    });
    console.log(JSON.stringify({ event: "key_issued", key_id: keyId }));
    return json(201, { key_id: keyId, key });
  }

  async function listKeys(env: Env): Promise<Response> {
    const nowSeconds = Math.floor(deps.now() / 1000);
    const entries = await index(env).list();
    const keys = await Promise.all(
      entries.map(async (entry) => {
        const stats = await env.RELAY_KEY.get(env.RELAY_KEY.idFromName(entry.hash)).stats(nowSeconds);
        return { key_id: entry.key_id, label: entry.label, created_at: entry.created_at, ...stats };
      }),
    );
    return json(200, { keys });
  }

  async function revokeKey(keyId: string, env: Env): Promise<Response> {
    const entry = await index(env).get(keyId);
    if (entry === null) return error(404, "not_found");
    // Revoke before unlisting, so a failure in between leaves a dead key that is still listed.
    await env.RELAY_KEY.get(env.RELAY_KEY.idFromName(entry.hash)).revoke();
    await index(env).remove(keyId);
    console.log(JSON.stringify({ event: "key_revoked", key_id: keyId }));
    return new Response(null, { status: 204 });
  }

  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const { pathname } = new URL(request.url);
      if (pathname === "/v1/push") {
        return request.method === "POST" ? push(request, env) : error(405, "method_not_allowed");
      }
      const keyPath = /^\/v1\/keys(?:\/([^/]+))?$/.exec(pathname);
      if (keyPath === null) return error(404, "not_found");
      if (!(await isAdmin(request, env))) return error(401, "unauthorized");
      const keyId = keyPath[1];
      if (keyId === undefined) {
        if (request.method === "POST") return issueKey(request, env);
        if (request.method === "GET") return listKeys(env);
        return error(405, "method_not_allowed");
      }
      return request.method === "DELETE" ? revokeKey(keyId, env) : error(405, "method_not_allowed");
    },
  };
}

function index(env: Env) {
  return env.KEY_INDEX.get(env.KEY_INDEX.idFromName(INDEX_NAME));
}

/** An unset admin token admits nobody. */
async function isAdmin(request: Request, env: Env): Promise<boolean> {
  const token = bearerToken(request);
  if (!env.RELAY_ADMIN_TOKEN || token === null) return false;
  return constantTimeEqual(token, env.RELAY_ADMIN_TOKEN);
}

/** The body as text, or null when it is bigger than any valid request. */
async function readBody(request: Request): Promise<string | null> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > BODY_MAX_BYTES) return null;
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > BODY_MAX_BYTES) return null;
  return new TextDecoder().decode(bytes);
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function error(status: number, code: string): Response {
  return json(status, { error: code });
}
