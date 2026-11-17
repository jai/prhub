// Ask's comments on a PR's Linear tickets: proposed by the agent, shown as a card, posted only on the person's yes.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { linearPostedNow, postAskLinear } from "../../src/ask-linear.ts";
import {
  askOnSubscription,
  subscriptionChat,
  type SubscriptionRecord,
} from "../../src/ask-subscription.ts";
import type { Env } from "../../src/env.ts";
import type { RepoFullName, Sha } from "../../src/ids.ts";
import {
  canComment,
  postToLinear,
  proposalsOf,
  READ_ONLY_WORDS,
  userFor,
} from "../../src/linear-act.ts";
import type { WriteClaim } from "../../src/write-receipts.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const USERS = [
  {
    name: "Octo Bot",
    displayName: "octobot",
    url: "https://linear.app/acme/profiles/octobot",
    active: true,
    app: true,
  },
  {
    name: "Alex Doe",
    displayName: "alex",
    url: "https://linear.app/acme/profiles/alex",
    active: true,
  },
  {
    name: "Sam Roe",
    displayName: "sam.r",
    url: "https://linear.app/acme/profiles/sam.r",
    active: true,
  },
  {
    name: "Sam Rowe",
    displayName: "sam.rowe",
    url: "https://linear.app/acme/profiles/sam.rowe",
    active: true,
  },
  {
    name: "Old Bot",
    displayName: "oldbot",
    url: "https://linear.app/acme/profiles/oldbot",
    active: false,
  },
];

/** Linear as a stand-in: the users query, and `commentCreate` answered by `comment`. */
function linear(
  comment: (body: { query: string; variables?: Record<string, unknown> }) => unknown = () => ({}),
) {
  const asked: { query: string; variables?: Record<string, unknown> }[] = [];
  globalThis.fetch = (async (_url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body)) as {
      query: string;
      variables?: Record<string, unknown>;
    };
    asked.push(body);
    return Response.json(
      body.query.includes("users(")
        ? { data: { users: { nodes: USERS, pageInfo: { hasNextPage: false, endCursor: null } } } }
        : comment(body),
    );
  }) as typeof fetch;
  return asked;
}

const KEY = { LINEAR_API_KEY: "lin_api_synthetic" };

test("a written name reaches the one user it means: exact, or one letter off when only one is that close", () => {
  assert.equal(
    userFor("Octbot", USERS)?.displayName,
    "octobot",
    "one letter from octobot, and nobody else is",
  );
  assert.equal(userFor("OCTOBot", USERS)?.displayName, "octobot");
  assert.equal(userFor("AlexDoe", USERS)?.displayName, "alex", "a name, spaces aside");
  assert.equal(userFor("sam.r", USERS)?.displayName, "sam.r", "an exact name wins over a near one");
  assert.equal(userFor("samrow", USERS), null, "two users are one letter away: nobody is picked");
  assert.equal(userFor("alx", USERS), null, "a short name must be exact");
  assert.equal(userFor("Nobody", USERS), null);
});

test("a proposal becomes a card: the words as they post with each mention's name, and the profile URL Linear needs", async () => {
  linear();
  const [card, notTheirs, lost] = await proposalsOf(
    [
      {
        issue: "eng-12",
        body: "@Octbot please rename the flag. cc @alex, mail me at jai@acme.dev",
      },
      { issue: "OPS-1", body: "@Octbot hi" },
      { issue: "ENG-12", body: "@Nobody and @OldBot look" },
    ],
    async () => ["ENG-12"],
    KEY,
  );
  assert.equal(card.issue, "ENG-12");
  assert.equal(
    card.text,
    "@Octo Bot please rename the flag. cc @Alex Doe, mail me at jai@acme.dev",
  );
  assert.equal(
    card.post,
    "https://linear.app/acme/profiles/octobot please rename the flag. cc " +
      "https://linear.app/acme/profiles/alex, mail me at jai@acme.dev",
  );
  assert.deepEqual(card.mentions, [
    { written: "Octbot", user: { name: "Octo Bot", display_name: "octobot", agent: true } },
    { written: "alex", user: { name: "Alex Doe", display_name: "alex", agent: false } },
  ]);
  assert.equal(card.problem, null);
  assert.equal(notTheirs.problem, "OPS-1 isn't one of this PR's tickets.");
  assert.equal(
    lost.problem,
    "No one in Linear matches @Nobody, @OldBot.",
    "a deactivated user is nobody",
  );
  assert.equal(lost.text, "@Nobody and @OldBot look");
});

test("without a Linear connection a proposal still shows, saying how to post it", async () => {
  const [card] = await proposalsOf(
    [{ issue: "ENG-12", body: "@Octbot hi" }],
    async () => ["ENG-12"],
    {},
  );
  assert.equal(card.problem, "Connect Linear in Settings to post this.");
  assert.deepEqual(await proposalsOf([{ issue: "not a key", body: "x" }], async () => [], KEY), []);
});

test("posting gives the comment's link, a scope refusal says the key can only read, and anything else Linear's words", async () => {
  const proposal = {
    issue: "ENG-12",
    text: "@Octo Bot hi",
    post: "https://linear.app/acme/profiles/octobot hi",
    mentions: [],
    problem: null,
  };
  const asked = linear(() => ({
    data: {
      commentCreate: {
        success: true,
        comment: { id: "c1", url: "https://linear.app/c/1", agentSession: null },
      },
    },
  }));
  assert.deepEqual(
    await postToLinear(proposal, KEY),
    { url: "https://linear.app/c/1", session: null },
    "a comment that mentions no agent waits for no session",
  );
  assert.deepEqual(asked[0].variables, {
    issue: "ENG-12",
    body: "https://linear.app/acme/profiles/octobot hi",
  });
  linear(() => ({
    errors: [{ message: "Invalid scope: `write` required", extensions: { code: "FORBIDDEN" } }],
  }));
  assert.deepEqual(await postToLinear(proposal, KEY), { problem: READ_ONLY_WORDS, readOnly: true });
  linear(() => ({
    errors: [{ message: "x", extensions: { userPresentableMessage: "Issue is archived." } }],
  }));
  assert.deepEqual(await postToLinear(proposal, KEY), {
    problem: "Linear refused: Issue is archived.",
    readOnly: false,
  });
});

test("the write check comments on an issue that can't exist: not found means the key may write", async () => {
  const answer = (body: unknown) => async () => Response.json(body);
  assert.equal(
    await canComment(KEY, answer({ errors: [{ message: "Entity not found: Issue" }] })),
    true,
  );
  assert.equal(
    await canComment(
      KEY,
      answer({ errors: [{ message: "Forbidden", extensions: { code: "FORBIDDEN" } }] }),
    ),
    false,
  );
  assert.equal(await canComment(KEY, async () => new Response("", { status: 403 })), false);
  assert.equal(
    await canComment(KEY, answer({ errors: [{ message: "Something else" }] })),
    null,
    "unknown stays unknown",
  );
  assert.equal(await canComment({}), null);
});

const HEAD = "a".repeat(40) as Sha;
const REPO = "acme/api" as RepoFullName;

function world(answer: Record<string, unknown>) {
  const objects = new Map<string, string>();
  const r2 = {
    get: async (key: string) =>
      objects.has(key) ? { json: async () => JSON.parse(objects.get(key)!) } : null,
    put: async (key: string, value: string) => void objects.set(key, value),
  };
  const agent = {
    idFromName: (name: string) => name,
    get: () => ({ fetch: async () => Response.json(answer) }),
  };
  const env = { DIFFS: r2, AGENT: agent, CLAUDE_CODE_OAUTH_TOKEN: "oat", ...KEY } as unknown as Env;
  const receipts = new Map<string, "sending" | "done">();
  let readOnly = 0;
  const services = {
    claim: async (key: string): Promise<WriteClaim> => {
      const held = receipts.get(key);
      if (held) {
        return held === "done" ? "done" : "busy";
      }
      receipts.set(key, "sending");
      return "go";
    },
    finish: async (key: string, sent: boolean) =>
      void (sent ? receipts.set(key, "done") : receipts.delete(key)),
    readOnly: async () => void readOnly++,
    now: () => 5_000,
  };
  const record = () => JSON.parse(objects.get(`ask/${REPO}/7.json`)!) as SubscriptionRecord;
  return { env, services, record, readOnlyMarks: () => readOnly };
}

async function asked(w: ReturnType<typeof world>) {
  await askOnSubscription(
    REPO,
    7,
    { question: "Tag Octbot on the ticket to rename the flag", head: HEAD, anchor: null },
    { model: "claude-haiku-5-5", effort: "high" },
    w.env,
    {
      system: async () => "sys",
      grant: async () => ({ token: "t", repos: [REPO] }),
      diff: async () => "",
      budgetUsd: 1,
      readOnly: true,
      now: () => 1_000,
      linear: (raw) => proposalsOf(raw, async () => ["ENG-12"], w.env),
    },
  );
  return w.record().messages.at(-1)!;
}

test("an answer's proposed comment rides under it as a card, and posts only on the person's yes, once", async () => {
  const posts: unknown[] = [];
  linear((body) => {
    posts.push(body.variables);
    return {
      data: {
        commentCreate: {
          success: true,
          comment: {
            id: "c1",
            url: "https://linear.app/c/1",
            agentSession: {
              id: "s1",
              status: "pending",
              url: "https://linear.app/acme/agent-session/s1",
              appUser: { name: "Octo Bot" },
            },
          },
        },
      },
    };
  });
  const w = world({
    subtype: "success",
    text: "",
    session: "s1",
    entries: [],
    model: "m",
    costUsd: 0,
    linear: [{ issue: "ENG-12", body: "@Octbot rename the flag" }],
  });
  const answer = await asked(w);
  assert.equal(answer.text, "I drafted a comment on ENG-12.");
  assert.deepEqual(posts, [], "nothing posts with the answer");
  const card = subscriptionChat(w.record(), 2_000).messages.at(-1)!.linear![0];
  assert.deepEqual(card, {
    issue: "ENG-12",
    text: "@Octo Bot rename the flag",
    mentions: [
      { written: "Octbot", user: { name: "Octo Bot", display_name: "octobot", agent: true } },
    ],
    problem: null,
    state: "proposed",
    url: null,
    failure: null,
    session: null,
  });
  assert.equal("post" in card, false, "the phone reads the words, not the URLs that make mentions");

  const yes = await postAskLinear(REPO, 7, { message: answer.id, index: 0 }, w.env, w.services);
  assert.equal(yes.status, 200);
  const shown = (yes.body as ReturnType<typeof subscriptionChat>).messages.at(-1)!.linear![0];
  assert.equal(shown.state, "posted");
  assert.equal(shown.url, "https://linear.app/c/1");
  assert.deepEqual(
    shown.session,
    {
      id: "s1",
      agent: "Octo Bot",
      status: "pending",
      url: "https://linear.app/acme/agent-session/s1",
    },
    "the agent session the mention started",
  );
  assert.deepEqual(posts, [
    { issue: "ENG-12", body: "https://linear.app/acme/profiles/octobot rename the flag" },
  ]);
  await postAskLinear(REPO, 7, { message: answer.id, index: 0 }, w.env, w.services);
  assert.equal(posts.length, 1, "a second yes finds it posted");
  assert.equal(
    (await postAskLinear(REPO, 7, { message: answer.id, index: 1 }, w.env, w.services)).status,
    404,
  );
});

test("a refused post shows Linear's reason and can be tried again; a scope refusal marks the key read only", async () => {
  let refuse = true;
  linear(() =>
    refuse
      ? {
          errors: [
            { message: "Invalid scope: `write` required", extensions: { code: "FORBIDDEN" } },
          ],
        }
      : {
          data: {
            commentCreate: {
              success: true,
              comment: {
                id: "c2",
                url: "https://linear.app/c/2",
                agentSession: {
                  id: "s2",
                  status: "pending",
                  url: null,
                  appUser: { name: "Octo Bot" },
                },
              },
            },
          },
        },
  );
  const w = world({
    subtype: "success",
    text: "Here it is.",
    session: "s1",
    entries: [],
    model: "m",
    costUsd: 0,
    linear: [{ issue: "ENG-12", body: "@Octbot rename" }],
  });
  const answer = await asked(w);
  const no = await postAskLinear(REPO, 7, { message: answer.id, index: 0 }, w.env, w.services);
  const failed = (no.body as ReturnType<typeof subscriptionChat>).messages.at(-1)!.linear![0];
  assert.equal(failed.state, "failed");
  assert.equal(failed.failure, READ_ONLY_WORDS);
  assert.equal(w.readOnlyMarks(), 1);
  refuse = false;
  const again = await postAskLinear(REPO, 7, { message: answer.id, index: 0 }, w.env, w.services);
  assert.equal(
    (again.body as ReturnType<typeof subscriptionChat>).messages.at(-1)!.linear![0].state,
    "posted",
  );
});

test("a card that can't post refuses the yes with its reason", async () => {
  linear();
  const w = world({
    subtype: "success",
    text: "Ok.",
    session: "s1",
    entries: [],
    model: "m",
    costUsd: 0,
    linear: [{ issue: "ENG-12", body: "@Nobody look" }],
  });
  const answer = await asked(w);
  const no = await postAskLinear(REPO, 7, { message: answer.id, index: 0 }, w.env, w.services);
  assert.equal(no.status, 409);
  assert.deepEqual(no.body, { error: "No one in Linear matches @Nobody." });
});

test("Linear may start the agent's session a moment after the comment: it is asked again, briefly", async () => {
  const proposal = {
    issue: "ENG-12",
    text: "@Octo Bot hi",
    post: "https://linear.app/acme/profiles/octobot hi",
    mentions: [
      { written: "Octbot", user: { name: "Octo Bot", display_name: "octobot", agent: true } },
    ],
    problem: null,
  };
  let asks = 0;
  linear((body) => {
    if (body.query.includes("commentCreate")) {
      return {
        data: {
          commentCreate: {
            success: true,
            comment: { id: "c1", url: "https://linear.app/c/1", agentSession: null },
          },
        },
      };
    }
    asks++;
    return {
      data: {
        comment: {
          agentSession:
            asks < 2
              ? null
              : {
                  id: "s1",
                  status: "active",
                  url: "https://linear.app/acme/agent-session/s1",
                  appUser: { name: "Octo Bot" },
                },
        },
      },
    };
  });
  const posted = await postToLinear(proposal, KEY, async () => {});
  assert.ok("url" in posted);
  assert.equal(posted.session?.status, "active");
  assert.equal(asks, 2);
});

test("reading the chat asks Linear where a running session stands, at most every 30 s, and never once it ended", async () => {
  const w = world({
    subtype: "success",
    text: "Ok.",
    session: "s1",
    entries: [],
    model: "m",
    costUsd: 0,
    linear: [{ issue: "ENG-12", body: "@Octbot rename" }],
  });
  let status = "pending";
  let checks = 0;
  linear((body) => {
    if (body.query.includes("commentCreate")) {
      return {
        data: {
          commentCreate: {
            success: true,
            comment: {
              id: "c1",
              url: "https://linear.app/c/1",
              agentSession: { id: "s1", status, url: null, appUser: { name: "Octo Bot" } },
            },
          },
        },
      };
    }
    checks++;
    return {
      data: { agentSession: { id: "s1", status, url: null, appUser: { name: "Octo Bot" } } },
    };
  });
  const answer = await asked(w);
  await postAskLinear(REPO, 7, { message: answer.id, index: 0 }, w.env, w.services);
  const read = (now: number) => linearPostedNow(REPO, 7, w.env, w.record().messages, now);
  await read(5_000 + 10_000);
  assert.equal(checks, 0, "too soon");
  status = "complete";
  assert.equal(Object.values(await read(5_000 + 30_000))[0].session?.status, "complete");
  await read(5_000 + 90_000);
  assert.equal(checks, 1, "an ended session is not asked about again");
});
