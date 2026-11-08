# PRHub privacy policy

This policy covers PRHub, an iPhone app for reviewing GitHub pull requests (PRs), and the push relay that Jai Govindani
runs for it.

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

- **What is sent.** Which screen shows, such as the PR list or Settings, and actions such as signing in, pairing a
  Worker, opening a PR, a sync, and a change to the diff font. Opening a PR also sends how it was opened (an alert, the
  list or a link), whether the phone already had it, and how many milliseconds it took; an alert sends whether the
  phone fetched its PR before you tapped it, and how long that took. Failures send only a short error code, such as
  `code_refused`. Each event also carries the app version, the iOS version, the device model, the screen size, and the
  phone's language and time zone.
- **What is never sent.** Your GitHub username or email, repo and organization names, PR titles, file paths, code,
  comments, your Worker's address, your push token, and anything that you type. The app cannot attach these: each
  event can carry only values from a fixed list.
- **It is anonymous.** The app makes a random ID on your phone. It is not linked to your GitHub account, your Worker
  or your Apple account. PostHog makes no profile of you and does not find your location from your IP address. The app
  records no screen content, no taps and no session replays. It does not use the advertising identifier (IDFA) and
  does not track you across other companies' apps or websites.
- **Turn it off.** Open **Settings** and turn off **Share anonymous usage**. The app then sends nothing more and
  forgets its random ID. If you turn it on again, the app makes a new ID.
- **How long it is kept.** PostHog keeps each event for one year, then deletes it.

Debug builds, test runs and builds of this repo without a PostHog key send nothing.

## What your pr-worker keeps

Your pr-worker runs in your Cloudflare account, and only you control it.

- It keeps your GitHub token as a Cloudflare secret. It uses the token to read your PRs and to act on them for you.
- It keeps copies of your PRs in your Cloudflare storage: their descriptions, diffs, comments, checks and review state.
- It sends data to GitHub. It also sends data to Anthropic, if you give it an Anthropic API key.

With an Anthropic API key, the AI features send PR diffs, PR descriptions and your questions to Anthropic's API.
Anthropic bills these calls to your key, and Anthropic's terms cover that data.

## Push through Jai's relay

Push is optional. Without it, the app updates when you open it.

Apple accepts pushes for PRHub only from Jai's Apple developer account. To push, your pr-worker sends each wake through
Jai's relay, a Cloudflare Worker in Jai's account. A wake contains your phone's push token and the word `pr_sync`. It
contains no PR content.

- The relay sends the wake to Apple's push service and stores no push token and no message.
- For each push, the relay logs your relay key's ID, the push type and Apple's answer. Cloudflare keeps these logs
  for up to 7 days.
- Jai keeps a list of relay keys, each with a label such as your GitHub username, so that he can revoke a key.

## TestFlight

Apple distributes PRHub through TestFlight. When you send feedback or a crash report through TestFlight, Apple passes
it to Jai. [Apple's privacy policy](https://www.apple.com/legal/privacy/) covers the data that TestFlight collects.

## Contact

For questions about this policy, or to have your relay key revoked, open an issue on
[jai/prhub](https://github.com/jai/prhub/issues/new).
