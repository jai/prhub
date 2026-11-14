import assert from "node:assert/strict";
import { test } from "node:test";
import { cachedTickets, createTicketsTable, refreshTickets, TICKET_FRESH_MS } from "../src/ticket-cache.ts";
import { type Ticket, unresolved } from "../src/tickets.ts";
import { memorySql } from "./memory-sql.ts";

function index() {
  const sql = memorySql();
  sql.exec("CREATE TABLE pull_requests (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, ticket_keys TEXT)");
  createTicketsTable(sql);
  return sql;
}

const issue = (key: string, state = "In Progress"): Ticket => ({
  key, url: `https://linear.app/acme/issue/${key}`, title: "Retry uploads", state, state_type: "started",
  state_color: "#f2c94c", found: true,
});

/** Linear as a test has it: what it answers, and each call's keys. */
function linear(answer: (key: string) => Ticket | null) {
  const calls: string[][] = [];
  const ask = async (keys: string[]) => {
    calls.push(keys);
    return new Map(keys.flatMap((key) => {
      const ticket = answer(key);
      return ticket ? [[key, ticket] as const] : [];
    }));
  };
  return { calls, ask };
}

test("a key Linear answered within the hour is not asked again; after the hour it is", async () => {
  const sql = index();
  const { calls, ask } = linear((key) => key === "ENG-404" ? { ...unresolved(key), found: false } : issue(key));
  const first = await cachedTickets(sql, ["ENG-1", "ENG-404"], 0, ask);
  assert.deepEqual([...first.values()], [issue("ENG-1"), { ...unresolved("ENG-404"), found: false }]);
  const again = await cachedTickets(sql, ["ENG-1", "ENG-404"], TICKET_FRESH_MS - 1, ask);
  assert.deepEqual(again, first);
  assert.deepEqual(calls, [["ENG-1", "ENG-404"]]);
  await cachedTickets(sql, ["ENG-1", "ENG-2"], TICKET_FRESH_MS + 1, ask);
  assert.deepEqual(calls.at(-1), ["ENG-1", "ENG-2"]);
});

test("Linear not answering keeps what it said before, and is not asked again within the hour", async () => {
  const sql = index();
  await cachedTickets(sql, ["ENG-1"], 0, linear(issue).ask);
  const down = linear(() => null);
  assert.deepEqual(await cachedTickets(sql, ["ENG-1", "ENG-2"], TICKET_FRESH_MS + 1, down.ask),
    new Map([["ENG-1", issue("ENG-1")]]));
  assert.deepEqual((await cachedTickets(sql, ["ENG-1", "ENG-2"], TICKET_FRESH_MS + 2, down.ask)).size, 1);
  assert.equal(down.calls.length, 1);
});

test("each hour the held PRs' keys are asked again, a PR whose ticket moved is read again, and others' keys go", async () => {
  const sql = index();
  sql.exec("INSERT INTO pull_requests VALUES ('acme/app#7', 'acme/app', 7, ?), ('acme/app#8', 'acme/app', 8, ?)",
    JSON.stringify(["ENG-1"]), JSON.stringify(["ENG-2"]));
  await cachedTickets(sql, ["ENG-1", "ENG-2", "OLD-1"], 0, linear(issue).ask);
  sql.exec("UPDATE pull_requests SET ticket_keys = NULL WHERE id = 'acme/app#8'");
  const quiet = linear(issue);
  assert.deepEqual(await refreshTickets(sql, 1, quiet.ask), []);
  assert.deepEqual(quiet.calls, [], "nothing is stale yet");
  const moved = linear((key) => issue(key, "Done"));
  assert.deepEqual(await refreshTickets(sql, TICKET_FRESH_MS + 1, moved.ask),
    [{ id: "acme/app#7", repo: "acme/app", number: 7 }]);
  assert.deepEqual(moved.calls, [["ENG-1"]]);
  assert.deepEqual(sql.exec<{ key: string }>("SELECT key FROM tickets").toArray(), [{ key: "ENG-1" }]);
  assert.deepEqual(await refreshTickets(sql, 2 * TICKET_FRESH_MS + 2, linear((key) => issue(key, "Done")).ask), [],
    "the same answer reads nothing again");
});
