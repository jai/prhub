import type { KeyIndex, RelayKey } from "./index.ts";

/** Bindings: wrangler.jsonc `vars`, the two Durable Objects, and the secrets set with `wrangler secret put`. */
export interface Env {
  APNS_TOPIC: string;
  RELAY_KEY: DurableObjectNamespace<RelayKey>;
  KEY_INDEX: DurableObjectNamespace<KeyIndex>;
  RELAY_ADMIN_TOKEN?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_P8?: string;
}

/** Side effects the handler reaches through, so tests inject a fake APNs `fetch` and a fixed clock. */
export interface Deps {
  fetch: typeof fetch;
  /** Milliseconds since the epoch. */
  now: () => number;
}

/** The slice of Durable Object storage the stores use, so tests can back it with a Map. */
export interface Storage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  delete(key: string): Promise<boolean>;
  list<T>(options: { prefix: string }): Promise<Map<string, T>>;
}
