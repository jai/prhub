# Workers re-architecture (PRHub's side)

Status: approved 2026-11-10; building. The current move is in README.md, "Workers layout". Jai's own deployment
carries the full plan, with its private details, in his Agent Pager repo; this is the part that changes PRHub.

## Target

- **`prhub`**, the hosted Worker, is the only PRHub backend people use: sign in with the PRHub GitHub App, pushes
  straight to APNs. **`prhub-test`** is its hosted test copy, with a GitHub App of its own.
- **The library.** `worker/src/lib.ts` lets another Worker serve one person's PRs on their own token: it serves
  `serveOwner` under a path of its own, ticks `tickOwnerIndex` from its cron, and exports `AiJobs` and a subclass of
  `PrIndex` whose `deliverByHost` sends each push to the host's own devices. The two Workers never call each other.
  Contract: [docs/api.md](../api.md), "Library".
- **Gone:** self-hosting (pairing, `prhub://setup`, the setup page, `deploy/setup.sh`, the template, the deployment
  guide), the push relay (`relay/`, `docs/push-relay.md`) and the Worker's `pager` and `relay` push modes.

## Moves that touch this repo

1. The library (`lib.ts`, `deliverByHost`, `GET /export` and `POST /import`), tagged. Additive.
2. After the Agent Pager host has run on it for 3 days: the `pager` push mode and the export and import routes go.
3. `prhub-test` becomes hosted (needs its GitHub App). Then self-hosting and the relay go, in the Worker, the app
   (`PRHUB_SELF_HOSTED`, "Connect your own Worker") and the docs, with a PRHub release. The relay Worker is deleted 3
   days after its last request.

Each move is checked live before the next: the library by its host serving a real PR list and push; `prhub-test` by a
sign-in, a PR list and a push on a device.
