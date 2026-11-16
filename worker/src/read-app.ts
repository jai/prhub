/**
 * The read App (`GITHUB_READ_APP_ID`, `GITHUB_READ_APP_KEY`): on a self-hosted Worker, the PR index reads with a GitHub
 * App's installation tokens, so the reads cost each installation's hour, not the person's. Never on the hosted Worker.
 *
 * Each installation has its own token, and it reaches that installation's repos (and public ones) alone. So a read
 * goes once per installation, for the PRs its account owns, and the answers are merged. PRs of an owner without an
 * installation are read as before (`GITHUB_READ_TOKEN`, else `GITHUB_TOKEN`), and so are writes and every question
 * about the viewer (`readsAsAnyone`). A token GitHub won't mint reads as before too.
 */
import { ASK_PERMISSIONS, appJwt } from "./app-token.ts";
import { type Env, isSet } from "./env.ts";

/** One installation's reads: its token, and the key its rate-limit backoff is held under (`rate-limit.ts`). */
type ReadAs = NonNullable<Env["GITHUB_READ_AS"]>;

interface Installed {
  id: number;
  login: string;
  type: string;
}

/** How long the list of installations is taken as current: a new installation is read with its token within it. */
export const INSTALLATIONS_MS = 10 * 60_000;
/** A token is minted again when less than this is left of its hour. */
export const TOKEN_MARGIN_MS = 5 * 60_000;

type Fetcher = typeof fetch;
const fetchAnywhere: Fetcher = (input, init) => fetch(input, init);

/** The read App's id and PKCS#8 key; null when either is unset, and always on the hosted Worker. */
export function readApp(env: Env): { id: string; key: string } | null {
  if (isSet(env.SIGNED_IN_USER_ID) || env.HOSTED === "on") {
    return null;
  }
  return isSet(env.GITHUB_READ_APP_ID) && isSet(env.GITHUB_READ_APP_KEY)
    ? { id: env.GITHUB_READ_APP_ID, key: env.GITHUB_READ_APP_KEY }
    : null;
}

function headers(jwt: string): Record<string, string> {
  return {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${jwt}`,
    "User-Agent": "pr-viewer",
  };
}

/** Per isolate, per App: its installations, and when they were read. */
const installedOf = new Map<string, { at: number; list: Promise<Installed[]> }>();
/** Per isolate, per App and installation: a token, and when it expires (ms). */
const tokensOf = new Map<string, Promise<{ token: string; expiresAt: number }>>();

/**
 * The App's installations on all of an account's repos, read once per `INSTALLATIONS_MS`. None when GitHub won't say:
 * everything reads as before.
 */
export function installations(
  app: { id: string; key: string },
  fetcher: Fetcher = fetchAnywhere,
  now = Date.now(),
): Promise<Installed[]> {
  const kept = installedOf.get(app.id);
  if (kept && now - kept.at < INSTALLATIONS_MS) {
    return kept.list;
  }
  const list = (async () => {
    const jwt = await appJwt(app, Math.floor(now / 1000));
    const response = await fetcher("https://api.github.com/app/installations?per_page=100", {
      headers: headers(jwt),
    });
    if (!response.ok) {
      throw new Error(`GitHub answered ${response.status} for the read App's installations`);
    }
    const found = (await response.json()) as {
      id: number;
      account: { login: string; type: string } | null;
      repository_selection?: string;
    }[];
    // Only an installation on every repo stands for its owner: one on some would miss the PRs of the others.
    return found.flatMap((one) =>
      one.account && one.repository_selection === "all"
        ? [{ id: one.id, login: one.account.login, type: one.account.type }]
        : [],
    );
  })().catch(() => {
    installedOf.delete(app.id);
    return [] as Installed[];
  });
  installedOf.set(app.id, { at: now, list });
  return list;
}

/**
 * Installation `id`'s token, read only (`ASK_PERMISSIONS`), kept until `TOKEN_MARGIN_MS` before it expires. Concurrent
 * reads share one mint. Throws when GitHub won't mint it.
 */
export async function installationToken(
  app: { id: string; key: string },
  id: number,
  fetcher: Fetcher = fetchAnywhere,
  now = Date.now(),
): Promise<string> {
  const name = `${app.id}:${id}`;
  const kept = tokensOf.get(name);
  if (kept) {
    const held = await kept.catch(() => null);
    if (held && held.expiresAt - now > TOKEN_MARGIN_MS) {
      return held.token;
    }
    if (tokensOf.get(name) === kept) {
      tokensOf.delete(name);
    }
  }
  const minted = (async () => {
    const jwt = await appJwt(app, Math.floor(now / 1000));
    const response = await fetcher(`https://api.github.com/app/installations/${id}/access_tokens`, {
      method: "POST",
      headers: headers(jwt),
      body: JSON.stringify({ permissions: ASK_PERMISSIONS }),
    });
    if (!response.ok) {
      throw new Error(`GitHub answered ${response.status} minting a read App token`);
    }
    const { token, expires_at: expiresAt } = (await response.json()) as {
      token: string;
      expires_at: string;
    };
    return { token, expiresAt: Date.parse(expiresAt) };
  })();
  tokensOf.set(name, minted);
  minted.catch(() => {
    if (tokensOf.get(name) === minted) {
      tokensOf.delete(name);
    }
  });
  return (await minted).token;
}

/** A token that failed a read is minted again next time: it may have been revoked. */
function forgetToken(app: { id: string }, readAs: ReadAs): void {
  tokensOf.delete(`${app.id}:${readAs.key.slice("app:".length)}`);
}

/** The env one installation's reads go with. */
async function envFor(
  env: Env,
  app: { id: string; key: string },
  installed: Installed,
  fetcher: Fetcher,
): Promise<Env | null> {
  try {
    const token = await installationToken(app, installed.id, fetcher);
    return { ...env, GITHUB_READ_AS: { token, key: `app:${installed.id}` } };
  } catch {
    return null;
  }
}

/**
 * `items` grouped by the env that reads them: one group per installation that owns some, and one with `env` itself
 * for the rest. With no read App, one group, `env` with every item.
 */
export async function readGroups<Item>(
  env: Env,
  items: Item[],
  ownerOf: (item: Item) => string,
  fetcher: Fetcher = fetchAnywhere,
): Promise<{ env: Env; items: Item[] }[]> {
  const app = readApp(env);
  if (!app || items.length === 0) {
    return [{ env, items }];
  }
  const byOwner = new Map(
    (await installations(app, fetcher)).map((one) => [one.login.toLowerCase(), one]),
  );
  const grouped = new Map<Installed | null, Item[]>();
  for (const item of items) {
    const installed = byOwner.get(ownerOf(item).toLowerCase()) ?? null;
    grouped.set(installed, [...(grouped.get(installed) ?? []), item]);
  }
  const groups: { env: Env; items: Item[] }[] = [];
  const rest: Item[] = grouped.get(null) ?? [];
  for (const [installed, owned] of grouped) {
    if (!installed) {
      continue;
    }
    const reader = await envFor(env, app, installed, fetcher);
    if (reader) {
      groups.push({ env: reader, items: owned });
    } else {
      rest.push(...owned);
    }
  }
  return rest.length > 0 ? [...groups, { env, items: rest }] : groups;
}

/**
 * The searches' readers: each installation's env, and `env` itself with `exclude`, the qualifiers that leave out the
 * owners an installation searched, so the person's token reads only the rest. With no read App, `env` alone.
 */
export async function searchGroups(
  env: Env,
  fetcher: Fetcher = fetchAnywhere,
): Promise<{ env: Env; exclude: string }[]> {
  const app = readApp(env);
  if (!app) {
    return [{ env, exclude: "" }];
  }
  const groups: { env: Env; exclude: string }[] = [];
  const searched: Installed[] = [];
  for (const installed of await installations(app, fetcher)) {
    const reader = await envFor(env, app, installed, fetcher);
    if (reader) {
      groups.push({ env: reader, exclude: "" });
      searched.push(installed);
    }
  }
  const exclude = searched
    .map((one) => `-${one.type === "Organization" ? "org" : "user"}:${one.login}`)
    .join(" ");
  return [...groups, { env, exclude }];
}

/** Runs `read` with each group's env; a token that failed is minted again on the next read. */
export async function eachGroup<Item, Answer>(
  groups: { env: Env; items: Item[] }[],
  read: (items: Item[], env: Env) => Promise<Answer>,
): Promise<Answer[]> {
  return Promise.all(
    groups.map(async (group) => {
      try {
        return await read(group.items, group.env);
      } catch (error) {
        const app = readApp(group.env);
        if (app && group.env.GITHUB_READ_AS) {
          forgetToken(app, group.env.GITHUB_READ_AS);
        }
        throw error;
      }
    }),
  );
}
