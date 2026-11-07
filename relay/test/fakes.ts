import type { Deps, Env, Storage } from "../src/env.ts";
import { createRelay } from "../src/relay.ts";
import { KeyIndexStore, KeyRecordStore } from "../src/stores.ts";

export class MemoryStorage implements Storage {
  readonly map = new Map<string, unknown>();
  async get<T>(key: string) {
    return structuredClone(this.map.get(key)) as T | undefined;
  }
  async put<T>(key: string, value: T) {
    this.map.set(key, structuredClone(value));
  }
  async delete(key: string) {
    return this.map.delete(key);
  }
  async list<T>({ prefix }: { prefix: string }) {
    const out = new Map<string, T>();
    for (const [key, value] of this.map) if (key.startsWith(prefix)) out.set(key, structuredClone(value) as T);
    return out;
  }
}

/** A namespace whose stubs are the stores themselves, one per name, as a Durable Object would be. */
function namespace<T>(make: () => T) {
  const instances = new Map<string, T>();
  return {
    instances,
    idFromName: (name: string) => name,
    get(id: string) {
      let instance = instances.get(id);
      if (instance === undefined) instances.set(id, (instance = make()));
      return instance;
    },
  };
}

export async function testPem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const base64 = btoa(String.fromCharCode(...der));
  return `-----BEGIN PRIVATE KEY-----\n${base64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
}

export const ADMIN = "admin-token-for-tests";

export interface Sent {
  url: string;
  headers: Record<string, string>;
  body: unknown;
}

/** A relay over in-memory Durable Objects, a settable clock and a recording APNs. */
export async function harness(options: { apns?: (sent: Sent) => Response | Promise<Response>; pem?: string } = {}) {
  const env = {
    APNS_TOPIC: "com.example.public",
    RELAY_ADMIN_TOKEN: ADMIN,
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: "TEAM123456",
    APNS_KEY_P8: options.pem ?? (await testPem()),
  } as Record<string, unknown>;
  const keyStores = namespace(() => new KeyRecordStore(new MemoryStorage()));
  const indexStorage = new MemoryStorage();
  const indexStores = namespace(() => new KeyIndexStore(indexStorage, env));
  env.RELAY_KEY = keyStores;
  env.KEY_INDEX = indexStores;

  const sent: Sent[] = [];
  const clock = { ms: Date.UTC(2026, 10, 5, 12, 0, 30) };
  const deps: Deps = {
    now: () => clock.ms,
    fetch: (async (input: string, init: RequestInit) => {
      const entry = { url: input, headers: init.headers as Record<string, string>, body: JSON.parse(init.body as string) };
      sent.push(entry);
      return options.apns ? options.apns(entry) : new Response(null, { status: 200, headers: { "apns-id": "id-1" } });
    }) as unknown as typeof fetch,
  };
  const relay = createRelay(deps);
  const call = (method: string, path: string, token: string | null, body?: unknown) =>
    relay.fetch(
      new Request(`https://relay.test${path}`, {
        method,
        headers: token === null ? {} : { authorization: `Bearer ${token}` },
        body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
      }),
      env as unknown as Env,
    );
  const issue = async (label = "someone") => {
    const response = await call("POST", "/v1/keys", ADMIN, { label });
    return (await response.json()) as { key_id: string; key: string };
  };
  return { env, sent, clock, call, issue, indexStorage, keyStores };
}

export function pushBody(overrides: Record<string, unknown> = {}) {
  return {
    device_token: "ab".repeat(32),
    apns_env: "production",
    push_type: "alert",
    priority: 10,
    collapse_id: "alert-1",
    expiration: 1767225600,
    payload: { aps: { alert: { title: "hi" } } },
    ...overrides,
  };
}
