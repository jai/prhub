# PRHub privacy policy

This policy covers PRHub, an iPhone app for reviewing GitHub pull requests (PRs), with a Worker you run yourself.

If you sign in with GitHub, you use the hosted PRHub service instead, and
[its privacy policy](docs/privacy/hosted.md) applies.

With your own Worker, PRHub sends your data only to a backend that you deploy and control: a pr-worker in your own Cloudflare account. Jai
does not receive your GitHub token, your PRs or your Anthropic API key. PRHub has no tracking, no ads and no accounts with
Jai. It sends anonymous usage data, which you can turn off: see [Anonymous usage data](#anonymous-usage-data).

## What the app sends

The app connects only to your pr-worker, at the address in the setup link that you open or scan. It sends these items
there:

- A device secret that the app makes when you pair it. The pr-worker uses it to recognize your phone.
- Your actions on PRs, such as reviews, comments and merges. The pr-worker posts them to GitHub as you.
- Your questions to Ask AI, when that feature is on.
- Short reports of each sync and of how long a PR took to open, for your pr-worker's own use.
- Your phone's push token, when push is on. The pr-worker uses it to wake the app when a PR changes.

The app uses the camera only to read the setup QR code. It keeps no image.

In "Try with sample PRs", the app sends nothing to GitHub or to a Worker. The sample PRs and what you do with them stay
on your phone.

## Anonymous usage data

The app tells Jai which screens and features people use, so that he can make PRHub better. It sends this data to
PostHog, an analytics service that processes it for Jai in its EU region (Frankfurt).

- **What is sent.** Which screen shows, such as the PR list or Settings, and what you do and how it went. Each event
  carries only values from a fixed list:
  - Signing in, pairing a Worker, a sync, and a change to the diff font. Failures send only a short error code, such as
    `code_refused`. That Scan could not open the camera, and why.
  - Opening a PR: how it was opened (an alert, the list or a link), whether the phone already had it, and how many
    milliseconds it took. An alert sends whether the phone fetched its PR before you tapped it, and how long that took.
  - A request to the Worker that fails: what it was for (such as the PR list, your settings or Feedback) and its HTTP
    status, or that the phone was offline.
  - Sending feedback: whether it went through, whether it started a new chat, how many screenshots it had, its size
    and how long it took, or why it failed.
  - An action on a PR, such as a review, a comment, a merge or a description edit: which kind of action it was, and
    whether GitHub took it, the phone saved it to send later, or why it failed (such as `offline` or `refused`).
  - Key lines and a rewritten description from the AI: whether they arrived, how long they took, and whether the
    description reads as AI slop, or why they failed.
  - A question to Ask AI: what asked it (typed, Explain, Explain this PR or Retry), whether it went through or why it
    failed, and that the AI gave no answer when it did not. A review or a Linear comment that the AI drafted: that it
    was used or posted, or why not.
  - Settings: setting or removing your Anthropic key, connecting or disconnecting Linear, signing out and deleting
    your account, and when one of these fails, a short code for why (such as `key_refused` or `unreachable`). Your
    answer to the offer to turn on review alerts.
  - A PR link from the share sheet: whether PRHub opened it. An alert you tapped that opened nothing, and why (no
    Worker yet, or the sample PRs). That the hosted Worker ended your session, and why. That Update could not open
    TestFlight.

  A failure that repeats is sent at most once a minute. Each event also carries the app version, the iOS version, the
  device model, the screen size, and the phone's language and time zone.
- **What is never sent.** Your GitHub username or email, repo and organization names, PR titles, file paths, code,
  comments, your Worker's address, your push token, anything that you type, the screenshots that you attach to
  feedback, and what the AI answers. The app cannot attach these: each event can carry only values from a fixed list.
- **It is anonymous.** The app makes a random ID on your phone. It is not linked to your GitHub account, your Worker
  or your Apple account. PostHog makes no profile of you and does not find your location from your IP address. The app
  records no screen content, no taps and no session replays. It does not use the advertising identifier (IDFA) and
  does not track you across other companies' apps or websites.
- **Turn it off.** Open **Settings** and turn off **Share anonymous usage**. The app then sends nothing more and
  forgets its random ID. If you turn it on again, the app makes a new ID.
- **How long it is kept.** PostHog keeps each event for one year, then deletes it.

Debug builds, test runs and builds of this repo without a PostHog key send nothing.

## Energy and performance reports

When your pr-worker's operator sets `METRICKIT=on`, the app sends your pr-worker the daily report iOS makes about PRHub
(Apple's MetricKit: CPU, energy, network, launch and hang times, and crash and hang call stacks of PRHub itself), with
the app build, iOS version and phone model. They contain no PR content. They go to your pr-worker only. Off unless set.

## What your pr-worker keeps

Your pr-worker runs in your Cloudflare account, and only you control it.

- It keeps your GitHub token as a Cloudflare secret. It uses the token to read your PRs and to act on them for you.
- It keeps copies of your PRs in your Cloudflare storage: their descriptions, diffs, comments, checks and review state.
- It sends data to GitHub. It also sends data to Anthropic, if you give it an Anthropic API key.

With an Anthropic API key, the AI features send PR diffs, PR descriptions and your questions to Anthropic's API.
Anthropic bills these calls to your key, and Anthropic's terms cover that data.

## Push

A Worker you run yourself sends no push: the app updates when you open it.

## TestFlight

Apple distributes PRHub through TestFlight. When you send feedback or a crash report through TestFlight, Apple passes
it to Jai. [Apple's privacy policy](https://www.apple.com/legal/privacy/) covers the data that TestFlight collects.

## Contact

For questions about this policy, open an issue on
[jai/prhub](https://github.com/jai/prhub/issues/new).
