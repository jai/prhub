// Linear mention matching and request/response adapters.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import {
  canComment,
  postToLinear,
  proposalsOf,
  READ_ONLY_WORDS,
  userFor,
} from "../../src/linear-act.ts";
import { USERS, linear, KEY } from "../support/linear-responses.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

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
