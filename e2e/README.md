# PRHub e2e

Agentic end-to-end tests and bug bashes for the PRHub iPhone app, with [e2e](https://github.com/tester-army/e2e).
The app runs on iOS Simulators in its Debug launch modes (`app/PRHub/Debug/PRHubScreenshots.swift`), so no Worker
and no GitHub are involved.

## Set up (once per app change)

```sh
cd e2e
npm install
./sims.sh          # build PRHub, then make, boot and install on "PRHub E2E 1" … "PRHub E2E 4"
npx e2e doctor
```

A new simulator does minutes of first-boot setup. Wait for it to settle before you start a bug bash.

## Model

`e2e.config.ts` uses your ChatGPT (Codex) sign-in when one is stored (`npx e2e login openai --device`), else
`OPENAI_API_KEY`. `E2E_PROVIDER=api` forces the key. `E2E_MODEL` picks the model (default `gpt-6.1-terra`; for
example `gpt-6-sol`, `gpt-6-astra`).

## Bug bash

```sh
OPENAI_API_KEY=… ./bugbash.sh            # every charter in charters.txt, one per booted simulator
OPENAI_API_KEY=… ./bugbash.sh some.txt   # other charters
```

- A charter is one line: `slug|mode|persona|goal`. Modes and personas are in `e2e.config.ts` and
  `e2e.bugbash.config.ts`.
- Output: `.e2e/bugbash/<run>/<slug>.log`, with `summary.md`, `report.json` and screenshots in `<slug>/`.
- Knobs: `BUGBASH_PARALLEL` (simulators at once, default 2: four time out on a busy Mac), `BUGBASH_STEPS`
  (default 15), `BUGBASH_TIMEOUT` in ms (default 900000), `BUGBASH_VIDEO=1`, and `BUGBASH_RUN` (the output
  directory's name).
- A finding is a claim. It counts as a bug only when its repro test in `tests/bugbash/` fails on it:

```sh
PRHUB_E2E_SIMS=<simulator udid> npx e2e run --config e2e.bugbash.config.ts --tag bugbash --target paired-1
```

Each repro launches its own mode (`tests/prhub.ts`), so one target runs them all. The repro tests fail until their
bug is fixed. Then remove the test's `bugbash` tag and keep it as a regression test. `npm run test:e2e` leaves the tagged tests out.
