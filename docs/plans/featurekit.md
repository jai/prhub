# FeatureKit

An app's users ask for changes from inside the app. A request from the app's owner starts a coding session that changes
the app's repo; a request from anyone else becomes a GitHub issue. Agent Pager and PR Hub both use it.

Status: step 1 done (PRKit v0.9.0, 2026-11-09). Decided by Jai: it lives in jai/prhub; owner → coding session; other
users → GitHub issue.

## Today

- `worker/src/feedback.ts`: every request starts a Managed Agents session on one builder agent and one self-hosted
  environment (`FEEDBACK_AGENT_ID`, `FEEDBACK_ENVIRONMENT_ID`, on `ASK_ANTHROPIC_API_KEY`). The repo, `jai/agent-pager`, is
  in the agent's system prompt. Jai is the only sender. All threads share one list, `feedback/threads.json`.
- App: `FeatureRequestsView` and `FeatureClient` in PRKit's `FeatureKit` target, on the `/feedback` routes; Agent
  Pager's Feedback tab shows it. Composer, image attachments and chat bubbles are PRKit's.
- Builder: `builder/worker.mjs` in jai/agent-pager, a LaunchAgent on the owner's Mac.

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
    "owner": { "action": "session", "agent_id": "agent_…", "environment_id": "env_…" },
    "user":  { "action": "issue", "labels": ["feature-request"] }
  },
  "prhub": { "repo": "jai/prhub", "owners": ["jai"], "owner": { "action": "session", … }, "user": { "action": "issue" } }
}
```

### Worker (`worker/src/featurekit/`)

```ts
type Sender = { login: string | null; role: "owner" | "user" };
type Action = { action: "session"; agent_id: string; environment_id: string }
            | { action: "issue"; labels: string[] }
            | { action: "off" };

interface FeatureApp { repo: string; owners: string[]; owner: Action; user: Action }

/** Who is asking: the hosted session's GitHub login, or the paired device of a single-owner Worker. */
function senderOf(request: Request, env: Env, app: FeatureApp): Promise<Sender>;

/** One route for both roles; the role picks the action. */
function submit(app: FeatureApp, sender: Sender, input: FeedbackInput, env: Env): Promise<FeatureThread>;

// Owner: today's feedback.ts, with the repo passed in instead of written in the prompt.
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

### Builder

- `builder/worker.mjs` moves to `jai/prhub/builder/` and takes the environment id and clone path from config, so one Mac
  can host each app's builder as its own LaunchAgent.
- The repo and clone path go in the session's first message, not the agent's system prompt, so one agent definition
  serves every app.

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
4. Builder: per-app config, moved to jai/prhub.
5. PR Hub: turn it on (`prhub` entry, builder LaunchAgent for jai/prhub, screen in Settings).

## Open questions

- Spam and cost for user requests: a per-user daily limit (`limits.ts` already exists) and an issue-writing model call
  well under a cent.
- Whether a PR Hub user may see an issue they filed once it's closed (link only, or status too).
