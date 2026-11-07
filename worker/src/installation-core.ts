/**
 * One installation of the PRHub GitHub App on the hosted Worker (docs/api.md, "Webhook routing"): which signed-in people
 * can see which of its repos, so a delivery about a repo reaches only their PR indexes. `Installation` (`account.ts`)
 * holds one per installation, named `installation:<id>`; this file is its logic over a key-value store, so a test runs
 * it without a Durable Object.
 *
 * Who sees what comes from each person's own token: `GET /user/installations/{id}/repositories` at sign-in and every few
 * hours (`join`), and `GET /repos/{repo}` when in doubt (`runChecks`). An installation token never answers it. A person
 * is in doubt about a repo the installation gained, or that a delivery named first, after their list was read; a
 * delivery for them then waits for their token's answer, and is dropped when it says no.
 */
import type { RepoFullName, Sha } from "./ids.ts";

/** What a delivery asks of a person's index: read this PR, or the PRs at this head (a check suite or a status). */
export type DeliveryTarget =
  | { kind: "pr"; repo: RepoFullName; number: number; author: string | null; reviewers: string[] }
  | { kind: "head"; repo: RepoFullName; sha: Sha };

export interface Member {
  user_id: string;
  login: string;
  /** When their list of this installation's repos was last read with their token. */
  refreshed_at: number;
}

/** A person's answer about one repo: from their list (visible) or from asking with their token. */
interface Seen {
  visible: boolean;
  at: number;
}

/** Deliveries waiting for a person's token to say whether they can see the repo. */
interface Check {
  user_id: string;
  repo: RepoFullName;
  targets: DeliveryTarget[];
  tries: number;
}

interface Meta {
  account: string | null;
  suspended: boolean;
}

/** The slice of `DurableObjectStorage` the installation uses; a test passes a Map. */
export interface ListStore {
  get<T>(key: string): Promise<T | undefined>;
  getMany<T>(keys: string[]): Promise<Map<string, T>>;
  put(entries: Record<string, unknown>): Promise<void>;
  delete(keys: string[]): Promise<void>;
  list<T>(prefix: string): Promise<Map<string, T>>;
  deleteAll(): Promise<void>;
}

export interface InstallationDeps {
  store: ListStore;
  /** Marks the delivery in the person's own PR index. */
  deliver(userId: string, target: DeliveryTarget, login: string): Promise<void>;
  /** Whether the person's own token can read the repo; null when it could not be asked (signed out counts as no). */
  canSee(userId: string, repo: RepoFullName): Promise<boolean | null>;
}

/** Checks one alarm runs; the rest wait for the next. */
export const CHECKS_PER_PASS = 10;
/** A check GitHub could not answer goes again this many times, then the delivery is left to the person's poll. */
export const CHECK_TRIES = 3;
/** Deliveries one check holds; more are the same PRs again, and the person's poll covers anything past them. */
const TARGETS_PER_CHECK = 20;

const repoKey = (repo: string) => repo.toLowerCase();
const memberKey = (userId: string) => `member:${userId}`;
const seenKey = (userId: string, repo: string) => `seen:${userId}:${repoKey(repo)}`;
const checkKey = (userId: string, repo: string) => `check:${userId}:${repoKey(repo)}`;
const addedKey = (repo: string) => `repo:${repoKey(repo)}`;

/** Whether a person is involved in a PR, so their index takes it even when it does not hold it yet. */
export function isInvolved(target: DeliveryTarget, login: string): boolean {
  const name = login.toLowerCase();
  return target.kind === "pr"
    && [target.author, ...target.reviewers].some((candidate) => candidate?.toLowerCase() === name);
}

export class InstallationCore {
  readonly #deps: InstallationDeps;

  constructor(deps: InstallationDeps) {
    this.#deps = deps;
  }

  /**
   * A person's token listed the repos it can see here: they replace what was known of them. A repo seen here for the
   * first time is dated now, so people whose lists are older ask about it before a delivery reaches them.
   */
  async join(member: { user_id: string; login: string }, repos: string[], account: string | null, now: number):
  Promise<void> {
    await this.#deleteFor(member.user_id, ["seen:"]);
    const known = await this.#deps.store.getMany<number>(repos.map(addedKey));
    const entries: Record<string, unknown> = {
      [memberKey(member.user_id)]: { ...member, refreshed_at: now } satisfies Member,
    };
    for (const repo of repos) {
      entries[seenKey(member.user_id, repo)] = { visible: true, at: now } satisfies Seen;
      if (!known.has(addedKey(repo))) {
        entries[addedKey(repo)] = now;
      }
    }
    if (account !== null) {
      entries.meta = { ...await this.#meta(), account } satisfies Meta;
    }
    await this.#putAll(entries);
  }

  /** The person left the installation, signed out of it on GitHub, or deleted their account: nothing of theirs stays. */
  async leave(userId: string): Promise<void> {
    await this.#deleteFor(userId, ["seen:", "check:"]);
    await this.#deps.store.delete([memberKey(userId)]);
  }

  /** `installation_repositories` `added`, or `installation` `created`: everyone listed before now is in doubt about them. */
  async reposAdded(repos: string[], now: number): Promise<void> {
    await this.#putAll(Object.fromEntries(repos.map((repo) => [addedKey(repo), now])));
  }

  /** `installation_repositories` `removed`: nobody is routed to them; each person's poll drops their rows. */
  async reposRemoved(repos: string[]): Promise<void> {
    const members = [...(await this.members()).keys()];
    await this.#deleteKeys(repos.flatMap((repo) => [
      addedKey(repo), ...members.flatMap((userId) => [seenKey(userId, repo), checkKey(userId, repo)]),
    ]));
  }

  async setSuspended(suspended: boolean): Promise<void> {
    await this.#deps.store.put({ meta: { ...await this.#meta(), suspended } satisfies Meta });
  }

  /** `installation` `deleted`: everything goes. Answers who was a member. */
  async forget(): Promise<string[]> {
    const members = [...(await this.members()).keys()];
    await this.#deps.store.deleteAll();
    return members;
  }

  async members(): Promise<Map<string, Member>> {
    const listed = await this.#deps.store.list<Member>("member:");
    return new Map([...listed.values()].map((member) => [member.user_id, member]));
  }

  /**
   * A delivery about one repo: marked now in the index of each member who can see it; queued for a check for each one
   * in doubt; never sent to anyone else. Nothing goes while the installation is suspended.
   */
  async route(target: DeliveryTarget, now: number): Promise<{ delivered: string[]; queued: string[] }> {
    const meta = await this.#meta();
    if (meta.suspended) {
      return { delivered: [], queued: [] };
    }
    const members = [...(await this.members()).values()];
    const seen = await this.#deps.store.getMany<Seen>(members.map((member) => seenKey(member.user_id, target.repo)));
    let addedAt = await this.#deps.store.get<number>(addedKey(target.repo));
    if (addedAt === undefined) {
      // A repo no list or event named yet: an "all repositories" install gained it. Everyone asks once.
      addedAt = now;
      await this.#deps.store.put({ [addedKey(target.repo)]: now });
    }
    const delivered: string[] = [];
    const queued: string[] = [];
    for (const member of members) {
      const answer = seen.get(seenKey(member.user_id, target.repo));
      const isCurrent = answer !== undefined && answer.at >= addedAt;
      if (isCurrent && answer.visible) {
        await this.#deps.deliver(member.user_id, target, member.login);
        delivered.push(member.user_id);
      } else if (!isCurrent && addedAt >= member.refreshed_at) {
        await this.#queue(member.user_id, target);
        queued.push(member.user_id);
      }
    }
    return { delivered, queued };
  }

  /** Asks each queued person's token about the repo, and delivers what was waiting to those who can see it. */
  async runChecks(now: number): Promise<{ isPending: boolean }> {
    const checks = [...(await this.#deps.store.list<Check>("check:")).values()].slice(0, CHECKS_PER_PASS);
    const members = await this.members();
    for (const check of checks) {
      const member = members.get(check.user_id);
      const visible = member ? await this.#deps.canSee(check.user_id, check.repo) : false;
      if (visible === null && check.tries + 1 < CHECK_TRIES) {
        await this.#deps.store.put({ [checkKey(check.user_id, check.repo)]: { ...check, tries: check.tries + 1 } });
        continue;
      }
      await this.#deps.store.delete([checkKey(check.user_id, check.repo)]);
      if (visible === null || !member) {
        continue;
      }
      await this.#deps.store.put({ [seenKey(check.user_id, check.repo)]: { visible, at: now } satisfies Seen });
      if (visible) {
        for (const target of check.targets) {
          await this.#deps.deliver(check.user_id, target, member.login);
        }
      }
    }
    return { isPending: (await this.#deps.store.list("check:")).size > 0 };
  }

  async #queue(userId: string, target: DeliveryTarget): Promise<void> {
    const key = checkKey(userId, target.repo);
    const held = await this.#deps.store.get<Check>(key);
    const same = JSON.stringify(target);
    const targets = (held?.targets ?? []).filter((one) => JSON.stringify(one) !== same);
    await this.#deps.store.put({
      [key]: {
        user_id: userId, repo: target.repo, targets: [...targets, target].slice(-TARGETS_PER_CHECK), tries: held?.tries ?? 0,
      } satisfies Check,
    });
  }

  async #meta(): Promise<Meta> {
    return await this.#deps.store.get<Meta>("meta") ?? { account: null, suspended: false };
  }

  async #deleteFor(userId: string, prefixes: string[]): Promise<void> {
    for (const prefix of prefixes) {
      await this.#deleteKeys([...(await this.#deps.store.list(`${prefix}${userId}:`)).keys()]);
    }
  }

  async #deleteKeys(keys: string[]): Promise<void> {
    if (keys.length > 0) {
      await this.#deps.store.delete(keys);
    }
  }

  async #putAll(entries: Record<string, unknown>): Promise<void> {
    if (Object.keys(entries).length > 0) {
      await this.#deps.store.put(entries);
    }
  }
}

/** `DurableObjectStorage` as a `ListStore`: its batch calls take at most 128 keys at a time. */
export function storageStore(storage: DurableObjectStorage): ListStore {
  const BATCH = 128;
  const chunks = <T>(items: T[]) => Array.from({ length: Math.ceil(items.length / BATCH) },
    (_, index) => items.slice(index * BATCH, (index + 1) * BATCH));
  return {
    get: (key) => storage.get(key),
    async getMany<T>(keys: string[]) {
      const found = new Map<string, T>();
      for (const chunk of chunks(keys)) {
        for (const [key, value] of await storage.get<T>(chunk)) {
          found.set(key, value);
        }
      }
      return found;
    },
    async put(entries) {
      for (const chunk of chunks(Object.entries(entries))) {
        await storage.put(Object.fromEntries(chunk));
      }
    },
    async delete(keys) {
      for (const chunk of chunks(keys)) {
        await storage.delete(chunk);
      }
    },
    list: (prefix) => storage.list({ prefix }),
    deleteAll: () => storage.deleteAll(),
  };
}
