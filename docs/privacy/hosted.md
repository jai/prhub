# Hosted PRHub privacy policy

This policy covers the hosted PRHub service: the server that you reach when you tap **Sign in with GitHub** in the
PRHub iPhone app. Jai Govindani runs it on Cloudflare. If you connect your own Worker instead, [PRIVACY.md](../../PRIVACY.md)
applies, and Jai receives none of your data.

The hosted service has no analytics, no tracking and no ads. It sells nothing and shares your data with nobody for
their own use.

## What the service stores

When you sign in, GitHub gives the service your GitHub user ID and username. It also gives tokens that act as you
through the PRHub GitHub App. The service stores these items:

- **Your GitHub tokens.** They are encrypted with AES-256-GCM before they are stored. They never go to your phone, a
  log or another person.
- **Your sessions.** Each signed-in phone has a session secret. The service stores only its SHA-256 hash.
- **Copies of your pull requests.** The service stores the pull requests on your list: titles, descriptions, diffs,
  comments, checks and review state. It also stores a list of the repos that you can see, for quick jump. It reads
  them from GitHub with your own token, so it holds only what you can see.
- **Your installations.** The service records which PRHub App installations you belong to and which of their repos
  you can see. It uses this record to send each GitHub notification only to the people who can see that repo.
- **Your Anthropic API key, if you give one.** It is encrypted as the tokens are, and never sent back to your phone.
- **AI answers.** Key lines, rewrites and the record of your Ask conversations, when you use them.
- **Your phone's push token**, when you allow notifications. The service uses it to send pushes to your phone.
- **Activity records.** The last 5,000 events of your account, such as syncs, pushes and errors, so that problems
  can be found. They contain no PR content.
- **Request counts.** The service counts your requests to enforce its limits. It counts sign-in attempts by a hash of
  the IP address, never the address itself.

## Where your data goes

- **GitHub** receives your reads and your actions, such as reviews, comments and merges, sent with your own token.
- **Anthropic** receives PR diffs, descriptions and your questions only when you give your own Anthropic API key and
  use an AI feature. The calls run on your key and in your Anthropic organization, and Anthropic's terms cover them.
- **Apple** receives the pushes for your phone through its push service.
- **Cloudflare** hosts the service and stores the data above. Cloudflare keeps the service's logs for up to 7 days.
  The logs can contain your GitHub user ID. They contain no tokens and no PR content.

## How long data is kept

| Data | Kept until |
|---|---|
| GitHub tokens and Anthropic key | You sign out of your last phone, revoke the PRHub App on GitHub, or delete your account |
| A session | You sign out of that phone, or 180 days pass |
| Copies of a pull request and its AI answers | 30 days after the pull request leaves your list, while you are signed in |
| Activity records | 5,000 newer events replace them |
| Sign-in attempt counts | The one-minute window ends |

When you sign out of your last phone, the service drops your tokens, your Anthropic key and your push tokens. It keeps
your copies of pull requests, so that they are there when you sign in again. To remove them, delete your account.

## Deleting your account

In PRHub, open **Settings** and tap **Delete Account**. The service then does these things:

1. It asks GitHub to revoke PRHub's authorization and every token GitHub issued to PRHub for you.
2. It deletes your account, your tokens, your Anthropic key, your sessions and your push tokens.
3. It deletes your copies of pull requests, AI answers, activity records and queued AI work.
4. It removes you from every installation, so no later GitHub notification reaches you.

Deletion is immediate and cannot be undone. The Ask agent, environment and vault that PRHub made in your Anthropic
organization stay there. Delete them in the Anthropic Console.

## Contact

For questions about this policy, open an issue on [jai/prhub](https://github.com/jai/prhub/issues/new).
