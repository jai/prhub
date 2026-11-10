// One person's state that GitHub can't give back, carried from one Worker to another when the index moves: the reviewed
// key-line ticks (`PrIndex`) and Ask's queue (`AiJobs`). `GET /export` reads it, `POST /import` adds what the index
// lacks; both answer the counts the index holds, so a move can compare them. One-person Workers only.
import { z } from "zod";
import { askQueue, type Env, isSet, prIndex } from "./env.ts";
import type { LimitSql } from "./limit-counter.ts";

const reviewedKeyLineRow = z.object({ pr: z.string(), head: z.string(), line: z.string(), at: z.number() });
const askRow = z.object({ id: z.string(), pr: z.string(), ask: z.string(), at: z.number(), error: z.string().nullable() });
const askChatRow = z.object({ pr: z.string(), chat: z.string(), at: z.number() });

const carriedIndexState = z.object({ reviewedKeyLines: z.array(reviewedKeyLineRow) });
const carriedAskState = z.object({ asks: z.array(askRow), askChats: z.array(askChatRow) });
const carriedState = carriedIndexState.extend(carriedAskState.shape);

export type CarriedIndexState = z.infer<typeof carriedIndexState>;
export type CarriedAskState = z.infer<typeof carriedAskState>;
export type CarriedState = z.infer<typeof carriedState>;

export interface CarriedCounts {
  reviewedKeyLines: number;
  asks: number;
  askChats: number;
}

export function readCarriedIndexState(sql: LimitSql): CarriedIndexState {
  return {
    reviewedKeyLines: sql.exec<z.infer<typeof reviewedKeyLineRow>>(
      "SELECT pr, head, line, at FROM reviewed_key_lines ORDER BY pr, head, line").toArray(),
  };
}

export function writeCarriedIndexState(sql: LimitSql, state: CarriedIndexState): number {
  for (const { pr, head, line, at } of state.reviewedKeyLines) {
    sql.exec("INSERT OR IGNORE INTO reviewed_key_lines (pr, head, line, at) VALUES (?, ?, ?, ?)", pr, head, line, at);
  }
  return sql.exec<{ count: number }>("SELECT count(*) AS count FROM reviewed_key_lines").toArray()[0]?.count ?? 0;
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
  const count = (table: string) =>
    sql.exec<{ count: number }>(`SELECT count(*) AS count FROM ${table}`).toArray()[0]?.count ?? 0;
  return { asks: count("asks"), askChats: count("ask_chats") };
}

async function exportCarriedState(env: Env): Promise<CarriedState> {
  return { ...await prIndex(env).exportCarried(), ...await askQueue(env).exportCarried() };
}

async function importCarriedState(env: Env, state: CarriedState): Promise<CarriedCounts> {
  const reviewedKeyLines = await prIndex(env).importCarried({ reviewedKeyLines: state.reviewedKeyLines });
  const asked = await askQueue(env).importCarried({ asks: state.asks, askChats: state.askChats });
  return { reviewedKeyLines, ...asked };
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
