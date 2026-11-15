# Offline first

Status: step 1 (audit) done 2026-11-15; steps 2 to 4 not started. Issue: #52.

Goal: with no network, PRHub opens on what it last loaded and lets you browse all of it. It says quietly that it is
offline and showing saved information. It never falls to a blank or error screen.

## Audit (2026-11-15, `main` at `19f2789`)

The table comes from reading the code. The tests in step 4 will check it on a device with no network.

"Kept" means the answer is on the device and still there after the app is quit and opened again.

| Screen (platforms) | Reads | Kept | Offline today | Writes |
| --- | --- | --- | --- | --- |
| PR list: For review, My PRs (iPhone stack, iPad split, Mac main window) | `GET /prs`, then each row's `/detail`, `/diff`, `/key-lines` | Yes. `PRMirror` keeps `rows.json` and a file per PR in the caches folder, which iOS may clear | Saved rows show. After a wait of up to 120 s, a "Not up to date. <system error>" banner. With no saved rows: "Loading PRs…", then "PRs didn't load" | "Remove me" swipe: direct. On failure the row comes back with an error banner |
| Merged PRs (filter) | `GET /prs/merged` | No, memory only | "Merged PRs didn't load" banner | None |
| PR page: description, changes, checks, reviews, comments, tickets (all) | The PR's kept file. If it isn't kept: `/detail` and `/diff` | Yes for listed PRs. No for a PR opened from a link or an alert that isn't in the list | A kept PR opens. A PR that isn't kept: "Reading this PR from GitHub" for up to 120 s, then "Couldn't read this PR" with Try again. Avatars come from the system URL cache | Comment, reply, description edit, resolve, checkbox, merge, update branch: all direct, errors shown inline or as a notice. Drafts are kept on disk |
| Review bar and composer (all) | None | n/a | n/a | Approve, request changes, comment: direct. On failure "Review not sent" with Retry, and the text goes back in the box |
| Files changed and diff (all) | Same as the PR page | Same as the PR page | Same as the PR page | Viewed marks: direct, undone on failure. Line comments: kept as drafts |
| Key lines (all) | `GET /key-lines` (polled) and `/key-lines-reviewed` | The row's own context only. Other contexts and the reviewed ticks: memory only | A network error counts as "still working", so it shows "Reading the change…" for as long as the network is gone. Reviewed ticks fail silently | Tick a line: direct, undone with a notice on failure |
| Ask (all) | `GET /prs/{repo}/{n}/ask` (polled) | No, memory only, and each open is a new session | "Can't reach the Worker. The chat shows again when it's back." It keeps polling | Question, and posting to Linear: direct. On failure: failed, with Retry. Unsent question: memory only |
| Feedback (iPhone and iPad tab, Mac window; FeedbackKit) | `GET /feedback`, `GET /feedback/{id}` | No, memory only | Error text | Send: direct, with a client reference so a resend counts once. On failure the draft comes back |
| Settings and account (iPhone tab, Mac Settings) | `GET /device/config`, one try | Yes, the last config is kept, and a failed read keeps it silently | Works on the kept config | Keys, delete account, sign out, disconnect: direct. Sign out and disconnect forget the account on the device even if the call fails |
| Onboarding, pairing, sign-in (all) | `POST /device/pair`, `/auth/github/*` | The Worker address and secret, in the Keychain | The right screen opens offline. Pairing and sign-in fail with "unreachable" | n/a |
| Notification extension (iOS) | `/detail`, `/diff`, `/key-lines`, with a 6 s limit | Writes into the PR mirror | The alert arrives unchanged | None |

There are no widgets, menu bar extra, search screen or repo index.

## Findings

- **Writes are not queued in a release.** PRKit has an outbox interface, but the app's only outbox is a Debug-build
  check that keeps its jobs in memory. In a release a write goes to the Worker or fails, so step 2 must cover writes
  as well.
- **Every read waits up to 120 s for a network** while the app is in front. The read is cut off by the 120 s timeout
  and no other signal, so a screen with no kept data waits two minutes before it says anything. There is no URL
  cache, because the sessions are ephemeral.
- **No offline signal.** A network monitor exists and is read in one place, only to choose the words for a queued
  write. Nothing shows that the app is offline. Nothing refreshes when the network comes back.
- **Kept data lives in the caches folder,** which iOS may empty when storage is low.
- **Memory-only screens:** Merged, Ask, Feedback, key lines at other contexts, and reviewed ticks.
- **Key lines never stops "reading"** while the network is gone.
- **DurableNetworking already has the parts:** a kept last-good answer per key that opens offline (`ReadStore`,
  `ReadState`, `Inbox`), a path watcher, a prefetcher, a persistent outbox and background uploads. PRHub uses only
  its transport.

## Plan

2. **Kept reads in PRKit.** Each read keeps its last good answer through DurableNetworking's `ReadStore`, outside the
   caches folder. A screen opens on it at once and refreshes in the background, with retry when the path comes back.
   Each screen has one state: nothing yet, saved at a time, fresh, or saved with a failed refresh. A view never spins
   over data it already has. Reads stop waiting 120 s when the device is known to be offline. Writes go through
   DurableNetworking's persistent outbox, so they survive a relaunch. Agent Pager embeds PRKit and gets the same.
3. **Every screen onto it,** most-used first: PR lists, a PR's page and files, reviews, Ask, Feedback. One quiet
   app-wide banner: "Offline — showing saved information".
4. **Tests:** launch offline after a warm run, and quit and reopen offline, on iPhone and Mac.
