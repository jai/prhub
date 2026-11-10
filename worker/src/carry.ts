// One person's state that GitHub can't give back, carried from one Worker to another when the index moves: the reviewed
// key-line ticks and the PRs held on Recently Reviewed (`PrIndex`), and Ask's queue (`AiJobs`). `GET /export` reads it, `POST /import` adds what the index
// lacks; both answer the counts the index holds, so a move can compare them. One-person Workers only.
import { z } from "zod";
import { askQueue, type Env, isSet, prIndex } from "./env.ts";
import type { LimitSql } from "./limit-counter.ts";

const reviewedKeyLineRow = z.object({ pr: z.string(), head: z.string(), line: z.string(), at: z.number() });
const reviewedPullRequestRow = z.object({ id: z.string(), repo: z.string(), number: z.number() });
const askRow = z.object({ id: z.string(), pr: z.string(), ask: z.string(), at: z.number(), error: z.string().nullable() });
const askChatRow = z.object({ pr: z.string(), chat: z.string(), at: z.number() });

const carriedIndexState = z.object({
  reviewedKeyLines: z.array(reviewedKeyLineRow), reviewedPullRequests: z.array(reviewedPullRequestRow),
});
const carriedAskState = z.object({ asks: z.array(askRow), askChats: z.array(askChatRow) });
const carriedState = carriedIndexState.extend(carriedAskState.shape);

export type CarriedIndexState = z.infer<typeof carriedIndexState>;
export type CarriedAskState = z.infer<typeof carriedAskState>;
export type CarriedState = z.infer<typeof carriedState>;

export interface CarriedIndexCounts {
  reviewedKeyLines: number;
  reviewedPullRequests: number;
}

export interface CarriedCounts extends CarriedIndexCounts {
  asks: number;
  askChats: number;
}

function countOf(sql: LimitSql, query: string): number {
  return sql.exec<{ count: number }>(query).toArray()[0]?.count ?? 0;
}

export function readCarriedIndexState(sql: LimitSql): CarriedIndexState {
  return {
    reviewedKeyLines: sql.exec<z.infer<typeof reviewedKeyLineRow>>(
      "SELECT pr, head, line, at FROM reviewed_key_lines ORDER BY pr, head, line").toArray(),
    reviewedPullRequests: sql.exec<z.infer<typeof reviewedPullRequestRow>>(
      "SELECT id, repo, number FROM pull_requests WHERE list = 'reviewed' ORDER BY id").toArray(),
  };
}

/**
 * Adds the ticks and the Recently Reviewed PRs the index lacks. A PR comes in as held on `reviewed`, so its next read
 * keeps it there while Jai's review stands; the caller marks each one to be read.
 */
export function writeCarriedIndexState(sql: LimitSql, state: CarriedIndexState): CarriedIndexCounts {
  for (const { pr, head, line, at } of state.reviewedKeyLines) {
    sql.exec("INSERT OR IGNORE INTO reviewed_key_lines (pr, head, line, at) VALUES (?, ?, ?, ?)", pr, head, line, at);
  }
  for (const { id, repo, number } of state.reviewedPullRequests) {
    sql.exec("INSERT OR IGNORE INTO pull_requests (id, repo, number, list) VALUES (?, ?, ?, 'reviewed')", id, repo, number);
  }
  return {
    reviewedKeyLines: countOf(sql, "SELECT count(*) AS count FROM reviewed_key_lines"),
    reviewedPullRequests: countOf(sql, "SELECT count(*) AS count FROM pull_requests WHERE list = 'reviewed'"),
  };
}

export function readCarriedAskState(sql: LimitSql): CarriedAskState {
  return {
    asks: sql.exec<z.infer<typeof askRow>>("SELECT id, pr, ask, at, error FROM asks ORDER BY at, id").toArray(),
    askChats: sql.exec<z.infer<typeof askChatRow>>("SELECT pr, chat, at FROM ask_chats ORDER BY pr").toArray(),
  };
}

export function writeCarriedAskState(sql: LimitSql, state: CarriedAskState): { asks: number; askChats: number } {
  for (const { id, pr, ask, at, error } of state.asks) {
    sql.exec("INSERT OR IGNORE INTO asks (id, pr, ask, at, error) VALUES (?, ?, ?, ?, ?)", id, pr, ask, at, error);
  }
  for (const { pr, chat, at } of state.askChats) {
    sql.exec("INSERT OR IGNORE INTO ask_chats (pr, chat, at) VALUES (?, ?, ?)", pr, chat, at);
  }
  return {
    asks: countOf(sql, "SELECT count(*) AS count FROM asks"),
    askChats: countOf(sql, "SELECT count(*) AS count FROM ask_chats"),
  };
}

async function exportCarriedState(env: Env): Promise<CarriedState> {
  return { ...await prIndex(env).exportCarried(), ...await askQueue(env).exportCarried() };
}

async function importCarriedState(env: Env, state: CarriedState): Promise<CarriedCounts> {
  const indexed = await prIndex(env).importCarried({
    reviewedKeyLines: state.reviewedKeyLines, reviewedPullRequests: state.reviewedPullRequests,
  });
  const asked = await askQueue(env).importCarried({ asks: state.asks, askChats: state.askChats });
  return { ...indexed, ...asked };
}

/** `GET /export` and `POST /import`, or null for any other route. Never on the hosted Worker. */
export async function carryRoute(pathname: string, request: Request, env: Env): Promise<Response | null> {
  if (isSet(env.SIGNED_IN_USER_ID)) {
    return null;
  }
  if (pathname === "/export" && request.method === "GET") {
    return Response.json(await exportCarriedState(env), { headers: { "Cache-Control": "no-store" } });
  }
  if (pathname === "/import" && request.method === "POST") {
    const parsed = carriedState.safeParse(await request.json().catch(() => null));
    if (!parsed.success) {
      return Response.json({ error: { code: "validation_error", message: "send what GET /export answers" } },
        { status: 400 });
    }
    return Response.json(await importCarriedState(env, parsed.data));
  }
  return null;
}
