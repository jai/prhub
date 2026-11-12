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
- **Everyone else**: with `issues`, a public issue on the repo ([api.md, "As GitHub issues"](api.md#as-github-issues)),
  opened with `ISSUES_TOKEN`; without it, `403`.

Each sender's chats are their own (`apps/<app>/users/<login>/` in R2). Logins compare without case.

## Routes

App Workers (bearer `CALLER_TOKEN`, headers `X-FeedbackKit-App` and `X-FeedbackKit-Login`): `GET/POST /feedback` and
`GET/POST /feedback/{id}`, with the bodies and answers of [api.md, Feedback](api.md#feedback). A repeat `client_ref`
answers the chat its first send made.

Runner (`POST`, bearer `RUNNER_TOKEN`): `/runner/poll`, `/runner/claim`, `/runner/result`, `/runner/agent`, as in
[api.md, Feedback](api.md#feedback), except:

- Each poll's work item adds `app`, `login`, `repo` and `role` (`owner` or `builder`).
- Claim, result and agent bodies carry the item's `app` and `login`; a claim answers them back with `repo` and `role`.

Screenshots of issues: `GET /images/<32 hex>.jpg|png`, with no auth.

## An app Worker

`FEEDBACKKIT_URL`, `FEEDBACKKIT_APP` (vars) and `FEEDBACKKIT_TOKEN` (secret, the FeedbackKit Worker's
`CALLER_TOKEN`). With all three, `/feedback` goes to the FeedbackKit Worker and `features.feedback` is on.
