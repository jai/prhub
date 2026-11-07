import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";
import { createRelay } from "./relay.ts";
import { type IndexEntry, KeyIndexStore, KeyRecordStore } from "./stores.ts";

// Thin Durable Object shells; the logic is in stores.ts, so the tests run it without `cloudflare:workers`.

export class RelayKey extends DurableObject<Env> {
  readonly #store: KeyRecordStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.#store = new KeyRecordStore(ctx.storage);
  }

  init(record: { key_id: string; label: string; created_at: string }) {
    return this.#store.init(record);
  }
  authorize(nowSeconds: number, count: boolean) {
    return this.#store.authorize(nowSeconds, count);
  }
  revoke() {
    return this.#store.revoke();
  }
  stats(nowSeconds: number) {
    return this.#store.stats(nowSeconds);
  }
}

export class KeyIndex extends DurableObject<Env> {
  readonly #store: KeyIndexStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.#store = new KeyIndexStore(ctx.storage, env);
  }

  add(entry: IndexEntry) {
    return this.#store.add(entry);
  }
  get(keyId: string) {
    return this.#store.get(keyId);
  }
  remove(keyId: string) {
    return this.#store.remove(keyId);
  }
  list() {
    return this.#store.list();
  }
  jwt(nowSeconds: number) {
    return this.#store.jwt(nowSeconds);
  }
  invalidateJwt(token: string) {
    return this.#store.invalidateJwt(token);
  }
}

export default createRelay({ fetch: (input, init) => fetch(input, init), now: () => Date.now() });
