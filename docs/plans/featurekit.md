# FeatureKit

An app's users ask for changes from inside the app. A request from the app's owner starts a coding session that changes
the app's repo; a request from anyone else becomes a GitHub issue. Agent Pager and PR Hub both use it.

Status: step 1 done (PRKit v0.9.0, 2026-11-09). The Worker is a queue and the agent runs on the owner's Mac subscription
(2026-11-09). Decided by Jai: it lives in jai/prhub; owner → coding session; other users → GitHub issue; no API spend
on the owner's sessions (one Managed Agents chat cost $10.43, mostly context re-read while it waited on CI).

## Today

- `worker/src/feedback.ts`: the Worker is the receiver and only queues. `POST /feedback` and `POST /feedback/<id>` keep
  the message and its screenshots in R2 as pending; `GET` answers the chat. It calls no model
  ([api.md, Feedback](../api.md#feedback)). On with `FEEDBACK_REPO` and `HUB_TOKEN`. Jai is the only sender.
- Runner: on the owner's Mac, outbound only. It polls `/feedback/runner/*`, claims a message and hands it to an agent
  through an adapter. Agent Pager's runner is its threads hub on the Mac mini, with an Orca adapter: a fresh clone per
  chat on the owner's build Mac and Claude Code launched there by `orca agent launch`; a reply goes into the same Orca chat; the
  agent's words come back from its transcript, the same read the Agents tab uses. The chat is an Agents thread too
  (jai/agent-pager `docs/api/feedback.md`).
- App: `FeatureRequestsView` and `FeatureClient` in PRKit's `FeatureKit` target, on the `/feedback` routes; Agent
  Pager's Feedback tab shows it. Composer, image attachments and chat bubbles are PRKit's. The contract did not change
  with the runner, so the app did not either.

## Shape

Usage first. An app turns FeatureKit on with one config entry and one screen:

```swift
// App
FeatureRequestsView(client: featureClient)   // list → conversation; New starts one
```

```jsonc
// Worker config, one entry per app (wrangler var FEATUREKIT_APPS)
{
  "agent-pager": {
    "repo": "jai/agent-pager",
    "owners": ["jai"],                       // GitHub logins
    "owner": { "action": "session", "runner": "agent-pager-hub" },
    "user":  { "action": "issue", "labels": ["feature-request"] }
  },
  "prhub": { "repo": "jai/prhub", "owners": ["jai"], "owner": { "action": "session", … }, "user": { "action": "issue" } }
}
```

### Worker (`worker/src/featurekit/`)

```ts
type Sender = { login: string | null; role: "owner" | "user" };
type Action = { action: "session"; runner: string }       // the runner that takes this app's owner sessions
            | { action: "issue"; labels: string[] }
            | { action: "off" };

interface FeatureApp { repo: string; owners: string[]; owner: Action; user: Action }

/** Who is asking: the hosted session's GitHub login, or the paired device of a single-owner Worker. */
function senderOf(request: Request, env: Env, app: FeatureApp): Promise<Sender>;

/** One route for both roles; the role picks the action. */
function submit(app: FeatureApp, sender: Sender, input: FeedbackInput, env: Env): Promise<FeatureThread>;

// Owner: today's feedback.ts: keep the message for the app's runner.
function startSession(app: FeatureApp, action: SessionAction, input: FeedbackInput, env: Env): Promise<FeatureThread>;
// User: one Messages call writes a title and body from the words and screenshots, then the GitHub App opens the issue.
function openIssue(app: FeatureApp, action: IssueAction, sender: Sender, input: FeedbackInput, env: Env): Promise<FeatureThread>;

interface FeatureThread { id: string; kind: "session" | "issue"; title: string; createdAt: string; url?: string }
```

- Threads are kept per app and per sender (`featurekit/<app>/<login>/threads.json`), so a user sees only their own.
- An issue thread is one message long: the user sees "Filed as #N" with a link, and the conversation ends there.
- Routes: `GET/POST /features/<app>` and `GET/POST /features/<app>/<id>`. `/feedback` stays as an alias for
  `agent-pager` until Agent Pager's app moves over.

### App (PRKit → `FeatureKit` target)

- `FeatureRequestsView`: a conversation list with New. On iPad and Mac it's a split view; on iPhone it pushes. Built from
  the same chat bubbles and composer as Ask and Agents threads (one component per thing).
- `FeatureClient`: wraps the routes above. The host app provides base URL and auth, just as `PRKitHost` does.

### Runner

- The Worker hands out work; a runner on the owner's machine pulls it (no inbound ports) and starts the agent through an
  adapter. Agent Pager's runner (threads hub, Orca adapter) is the first. Another adapter (a terminal agent, another
  machine) changes the runner, never the Worker or the app.
- The repo, the clone and the agent's brief belong to the runner, so one Worker serves every app.

### Screenshots on issues

GitHub's API has no image upload, so the Worker stores each screenshot in R2 under an unguessable key and links it in
the issue body. It keeps them while the issue is open.

## Alternative considered

- **Config file in each app's repo** (`featurekit.yml`, read through the GitHub App). It suits a public product better,
  but every request then needs a GitHub read, plus a cache to invalidate. Not worth it for two apps that already run their
  own Workers. Revisit if outside owners sign up.

## Steps

Each step ships on its own.

1. Move the Feedback screen and model into a PRKit `FeatureKit` target; Agent Pager uses it unchanged.
2. Worker: `featurekit/` with config, `senderOf` and per-sender threads; `startSession` is today's `feedback.ts`.
   `/feedback` becomes an alias.
3. User path: `openIssue` through the PRHub GitHub App; issue threads in the app.
4. Runner: Worker as queue, Agent Pager's threads hub as runner, Orca adapter (done 2026-11-09). Next: the runner takes
   a per-app config (repo, clone prefix, brief) so it serves PR Hub too.
5. PR Hub: turn it on (`prhub` entry, runner config for jai/prhub, screen in Settings).

## Open questions

- Spam and cost for user requests: a per-user daily limit (`limits.ts` already exists) and an issue-writing model call
  well under a cent.
- Whether a PR Hub user may see an issue they filed once it's closed (link only, or status too).
