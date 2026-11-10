import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import type { Env } from "../src/env.ts";
import { pullRequest } from "../src/github.ts";
import { botAuthorsOf, isBotAuthor, requestedByOf } from "../src/requester.ts";
import { lookUpTickets, resolvedTickets, ticketKeysOf, unresolved } from "../src/tickets.ts";
import { prNode } from "./pr-node.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

test("a title's bracketed keys come first, each once, then keys only the branch names", () => {
  assert.deepEqual(ticketKeysOf("[ENG-1686] [CORE-12] Count the bonus once [ENG-1686]", "jai/core-12-bonus"),
    { title: ["ENG-1686", "CORE-12"], branch: [] });
  assert.deepEqual(ticketKeysOf("fix: Count it once [ENG-1686, CORE-12]", "nm-663-a3-truid"),
    { title: ["ENG-1686", "CORE-12"], branch: ["NM-663"] });
});

test("words that only look like keys are no tickets", () => {
  assert.deepEqual(ticketKeysOf("Read UTF-8 names (see RFC-3986)", "alex/retry"), { title: [], branch: [] });
  assert.deepEqual(ticketKeysOf("Bump to v2", "release-2026-01"), { title: [], branch: [] });
});

test("without Linear a title's keys show unresolved and a branch's key does not show at all", async () => {
  const keys = ticketKeysOf("Retry [ENG-1]", "core-2-retry");
  const issues = await lookUpTickets([...keys.title, ...keys.branch], {} as Env);
  assert.deepEqual(resolvedTickets(keys, issues), [unresolved("ENG-1")]);
});

test("Linear's answer fills each ticket; a key it has no issue for is Not found, a branch's is dropped", async () => {
  let asked = "";
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    asked = String(init?.body);
    return Response.json({
      data: {
        t0: { identifier: "ENG-1", title: "Retry uploads", url: "https://linear.app/acme/issue/ENG-1",
          state: { name: "In Review", type: "started", color: "#f2c94c" } },
        t1: null,
        t2: null,
      },
      errors: [{ message: "Entity not found: Issue", path: ["t1"] }, { message: "Entity not found: Issue", path: ["t2"] }],
    });
  }) as typeof fetch;
  const keys = ticketKeysOf("Retry [ENG-1] [ENG-404]", "fix-12-retry");
  const issues = await lookUpTickets([...keys.title, ...keys.branch], { LINEAR_API_KEY: "key" } as Env);
  assert.match(asked, /issue\(id: \\"ENG-1\\"\)/);
  assert.deepEqual(resolvedTickets(keys, issues), [
    { key: "ENG-1", url: "https://linear.app/acme/issue/ENG-1", title: "Retry uploads", state: "In Review",
      state_type: "started", state_color: "#f2c94c", found: true },
    { ...unresolved("ENG-404"), found: false },
  ]);
});

test("Linear failing leaves every ticket unresolved, never Not found", async () => {
  const refuse = async () => Response.json({ errors: [{ message: "Authentication required" }] }, { status: 401 });
  globalThis.fetch = refuse as typeof fetch;
  const issues = await lookUpTickets(["ENG-1"], { LINEAR_API_KEY: "key" } as Env);
  assert.deepEqual(resolvedTickets({ title: ["ENG-1"], branch: [] }, issues), [unresolved("ENG-1")]);
});

const bots = botAuthorsOf({ BOT_AUTHORS: " Atlas-Bot ,other" });
const atlas = { __typename: "User", login: "atlas-bot" };

test("a bot is a GitHub App, a [bot] login or an account BOT_AUTHORS names", () => {
  assert.equal(isBotAuthor(atlas, bots), true);
  assert.equal(isBotAuthor({ __typename: "Bot", login: "renovate" }, new Set()), true);
  assert.equal(isBotAuthor({ __typename: "User", login: "dependabot[bot]" }, new Set()), true);
  assert.equal(isBotAuthor({ __typename: "User", login: "alex" }, bots), false);
});

test("the human behind a bot: a co-author that is no coding agent, then Requested by, then an assignee", () => {
  const trailers = { nodes: [{ commit: { message: "feat: x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"
    + "Co-authored-by: Art Doe <1234+artdoe@users.noreply.github.com>" } }] };
  const assignees = { nodes: [{ login: "other" }, { login: "sam", name: "Sam Roe", avatarUrl: "https://avatars.example/sam" }] };
  const node = { author: atlas, body: "Requested by: @octocat", trailers, assignees };
  assert.deepEqual(requestedByOf(node, bots),
    { login: "artdoe", name: "Art Doe", avatarUrl: "https://github.com/artdoe.png?size=80", source: "co_author" });
  assert.deepEqual(requestedByOf({ ...node, trailers: undefined }, bots),
    { login: "octocat", name: null, avatarUrl: "https://github.com/octocat.png?size=80", source: "body" });
  assert.deepEqual(requestedByOf({ ...node, trailers: undefined, body: "- **Requested by:** [Art Doe](https://x)" }, bots),
    { login: null, name: "Art Doe", avatarUrl: null, source: "body" });
  assert.deepEqual(requestedByOf({ ...node, trailers: undefined, body: "" }, bots),
    { login: "sam", name: "Sam Roe", avatarUrl: "https://avatars.example/sam", source: "assignee" });
  assert.equal(requestedByOf({ author: atlas, body: "" }, bots), null);
});

test("a detail says whether its author is a bot, who asked for it, and the tickets its title names", () => {
  const own = pullRequest(prNode({ title: "Retry [ENG-1]" }) as never, "jai", true, null, null, bots);
  assert.equal(own.detail.authorIsBot, false);
  assert.equal(own.detail.requestedBy, null);
  assert.deepEqual(own.detail.tickets, [unresolved("ENG-1")]);
  const botNode = prNode({ author: { __typename: "User", login: "atlas-bot", avatarUrl: "https://avatars.example/a" },
    body: "Requested by: @alex" });
  const bot = pullRequest(botNode as never, "jai", true, null, null, bots);
  assert.equal(bot.detail.authorIsBot, true);
  assert.equal(bot.detail.requestedBy?.login, "alex");
});
