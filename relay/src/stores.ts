// What the two Durable Objects keep, written against a small storage interface so node:test can run it on a Map.
import { importApnsKey, JWT_REUSE_SECONDS, mintApnsJwt } from "./apns.ts";
import type { Storage } from "./env.ts";
import { type Counters, consume, emptyCounters, sentLastDay } from "./rate.ts";

/** A relay key's record. The Durable Object holding it is named by the key's SHA-256, which is all that is kept. */
export interface KeyRecord {
  key_id: string;
  label: string;
  created_at: string;
  last_used_at: string | null;
  revoked: boolean;
}

export type Authorization =
  | { status: 200; key_id: string }
  | { status: 401 }
  | { status: 429; retry_after: number };

/** One key: its record and rate counters, in the Durable Object of that key. */
export class KeyRecordStore {
  readonly #storage: Storage;

  constructor(storage: Storage) {
    this.#storage = storage;
  }

  async init(record: { key_id: string; label: string; created_at: string }): Promise<void> {
    await this.#storage.put<KeyRecord>("record", { ...record, last_used_at: null, revoked: false });
  }

  /** Whether the key is live; with `count`, also whether it is within its limits, counting this push if so. */
  async authorize(nowSeconds: number, count: boolean): Promise<Authorization> {
    const record = await this.#storage.get<KeyRecord>("record");
    if (record === undefined || record.revoked) return { status: 401 };
    if (!count) return { status: 200, key_id: record.key_id };

    const counters = (await this.#storage.get<Counters>("counters")) ?? emptyCounters();
    const result = consume(counters, nowSeconds);
    if (!result.ok) return { status: 429, retry_after: result.retryAfter };
    await this.#storage.put("counters", result.counters);
    await this.#storage.put<KeyRecord>("record", { ...record, last_used_at: new Date(nowSeconds * 1000).toISOString() });
    return { status: 200, key_id: record.key_id };
  }

  async revoke(): Promise<void> {
    const record = await this.#storage.get<KeyRecord>("record");
    if (record !== undefined) await this.#storage.put<KeyRecord>("record", { ...record, revoked: true });
  }

  async stats(nowSeconds: number): Promise<{ last_used_at: string | null; sent_24h: number }> {
    const record = await this.#storage.get<KeyRecord>("record");
    const counters = (await this.#storage.get<Counters>("counters")) ?? emptyCounters();
    return { last_used_at: record?.last_used_at ?? null, sent_24h: sentLastDay(counters, nowSeconds) };
  }
}

/** A live key in the index; revoked keys leave it. */
export interface IndexEntry {
  key_id: string;
  hash: string;
  label: string;
  created_at: string;
}

export interface CachedJwt {
  token: string;
  iat: number;
  kid: string;
}

export interface ApnsSecrets {
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_P8?: string;
}

export function isFreshJwt(cached: CachedJwt | null | undefined, kid: string, nowSeconds: number): cached is CachedJwt {
  return cached != null && cached.kid === kid && nowSeconds - cached.iat < JWT_REUSE_SECONDS;
}

/** The key list and the one APNs provider token, in the single `index` Durable Object. */
export class KeyIndexStore {
  readonly #storage: Storage;
  readonly #secrets: ApnsSecrets;

  constructor(storage: Storage, secrets: ApnsSecrets) {
    this.#storage = storage;
    this.#secrets = secrets;
  }

  async add(entry: IndexEntry): Promise<void> {
    await this.#storage.put(`key:${entry.key_id}`, entry);
  }

  async get(keyId: string): Promise<IndexEntry | null> {
    return (await this.#storage.get<IndexEntry>(`key:${keyId}`)) ?? null;
  }

  async remove(keyId: string): Promise<void> {
    await this.#storage.delete(`key:${keyId}`);
  }

  async list(): Promise<IndexEntry[]> {
    const entries = await this.#storage.list<IndexEntry>({ prefix: "key:" });
    return [...entries.values()].sort((a, b) => a.created_at.localeCompare(b.created_at));
  }

  /**
   * A provider token under 50 minutes old, minted here when there is none. One copy for every isolate, because
   * Apple refuses a team whose token changes too often (`TooManyProviderTokenUpdates`).
   */
  async jwt(nowSeconds: number): Promise<CachedJwt | { error: "apns_not_configured" | "apns_key_invalid" }> {
    const { APNS_KEY_ID: kid, APNS_TEAM_ID: team, APNS_KEY_P8: p8 } = this.#secrets;
    if (!kid || !team || !p8) return { error: "apns_not_configured" };
    const stored = await this.#storage.get<CachedJwt>("jwt");
    if (isFreshJwt(stored, kid, nowSeconds)) return stored;
    let token: string;
    try {
      token = await mintApnsJwt(await importApnsKey(p8), kid, team, nowSeconds);
    } catch {
      return { error: "apns_key_invalid" };
    }
    const minted = { token, iat: nowSeconds, kid };
    await this.#storage.put("jwt", minted);
    return minted;
  }

  /** Drops the stored token after APNs refused it, unless another request has already replaced it. */
  async invalidateJwt(token: string): Promise<void> {
    const stored = await this.#storage.get<CachedJwt>("jwt");
    if (stored?.token === token) await this.#storage.delete("jwt");
  }
}
