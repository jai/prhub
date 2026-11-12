# FeedbackKit Worker

One Worker, `featurekit` (`worker/src/featurekit.ts`, config `deploy/featurekit/`), keeps every app's feedback. The
app talks to its own Worker as before (`/feedback`, [api.md, Feedback](api.md#feedback)). That Worker checks the
sender, as it does for every route, and forwards the request here with the app's name and the sender's GitHub login.

## Who gets what

`APPS` names each app's repo and its people:

```json
{"prhub": {"repo": "jai/prhub", "owners": ["jai"], "builders": ["poom"], "issues": true}}
```

- **Owners**: a chat with a coding agent on the owner's Mac. It makes the change, tests it and ships a build.
- **Builders**: the same chat, but the agent opens a pull request for an owner to merge. It never pushes to main.
- **Everyone else**: with `issues`, a public issue on the repo ([Issues](#issues)); without it, `403`.

Each sender's chats are their own (`apps/<app>/users/<login>/` in R2). Logins compare without case.

## Routes

App Workers (bearer `CALLER_TOKEN`, headers `X-FeedbackKit-App` and `X-FeedbackKit-Login`): `GET/POST /feedback` and
`GET/POST /feedback/{id}`, with the bodies and answers of [api.md, Feedback](api.md#feedback). A repeat `client_ref`
answers the chat its first send made.

Runner (`POST`, bearer `RUNNER_TOKEN`): [below](#the-runners-messages).

## Issues

- A new chat opens a public issue on the repo: the first line as the title, the words, the screenshots, and
  `From @<login> in PRHub (build <n>).` `ISSUES_TOKEN`'s account opens it. The chat answers with the issue's link.
- A reply in the app is a comment naming the sender. Comments others write on GitHub show in the chat as `agent`
  messages, `**@<login>:** <text>`.
- `GET /feedback` adds `notice`. `builderOnline` is always true and `isWorking` false.
- At most 10 new issues per sender in 24 hours (`429`); replies do not count.
- Screenshots are public at `GET /images/<32 hex>.jpg|png`, as the issue shows them.

## The runner's messages

Each poll's work item also carries `app`, `login`, `repo` and `role` (`owner` or `builder`). Claim, result and agent
bodies carry the item's `app` and `login`; a claim answers them back with `repo` and `role`.

| Route | Body | Answer |
|---|---|---|
| `/runner/poll` | `{orca, detail?}`: whether the agents' Mac answers, and why not | `{work: [{chat, message, first, at}]}`, oldest first |
| `/runner/claim` | `{chat, message}` | `{ok, text, build, first, title, images}`; `409` not pending; `404` |
| `/runner/result` | `{chat, message, status: "delivered" \| "failed", detail?}` | `{ok}`; `409` not claimed |
| `/runner/agent` | `{chat, messages: [{id, text, at}], isWorking, activity, thread}` | `{ok}`; `404` no chat |

- A message is `pending` → `delivering` (claim) → `delivered` or `failed` (result). A claim is a compare-and-swap on
  the message's R2 version, so it succeeds once. One left `delivering` for 15 minutes shows as failed and is never
  offered again.
- `agent` replaces the agent's side of the chat: all its messages so far (at most 500, 20,000 characters each).
- Storage, under each sender's `apps/<app>/users/<login>/`: `feedback/chats.json`,
  `feedback/chats/<id>/m/<at>-<message>.json`, their screenshots under `img/`, the agent's side in `agent.json`, the
  queue in `feedback/pending/`, the runner's last poll in `feedback/runner.json`. Issue chats are under
  `feedback/issues/`.

## An app Worker

`FEEDBACKKIT_URL`, `FEEDBACKKIT_APP` (vars) and `FEEDBACKKIT_TOKEN` (secret, the FeedbackKit Worker's
`CALLER_TOKEN`). With all three, `/feedback` goes to the FeedbackKit Worker and `features.feedback` is on.
