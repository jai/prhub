# AI model eval for PRHub (2026-11-07)

Which model and effort level should PRHub use by default for its two AI jobs? This page records the grades for 9
configurations: Claude Haiku 5.5, Sonnet 5.5 and Opus 5.5, each at effort `low`, `medium` and `high`.

## Recommendation

- **Ask AI: Haiku 5.5 at `high`.** It scored 4.33, within 0.3 of a second Opus 5.5 `high` run (4.58), with no hard
  failures. A question costs about $0.007, against $0.19 on Opus 5.5 `high`, and takes 27 s at the median.
  Runner-up: Opus 5.5 at `low` (4.33, $0.08 a question, 18 s).
- **Key lines: keep Opus 5.5 at `high`.** No cheaper configuration came within 0.3 of it with no hard failures.
  Runner-up: Sonnet 5.5 at `high`, which is what `ai.ts` runs today (Sonnet 5.5 with no effort set defaults to `high`).
  It costs half as much and answers in 5 s, but it scored 0.58 lower and named a line outside the diff once.

The rule for both jobs: take the cheapest configuration that scores within about 0.3 of the reference and has no hard
failures.

## What was measured

- **Key lines.** The request `generateKeyLines` sends (`worker/src/ai.ts`): the same system prompt, read from the
  file, and the diff with 100 lines of context. The only additions were `output_config.effort` and a cache breakpoint
  that cut the cost of the eval. The cost below is priced as production runs it, with no cache.
- **Ask AI.** The agent that `worker/scripts/ask-agent.mts` makes, with the same system prompt and tools, on a
  temporary agent and environment. Each session set its model and effort with a session override. Each session had
  the repository checked out at the PR's head and a $2 budget, as `ask.ts` sets. It had no GitHub API token. Each
  session got two questions, sent in `askPrompt` form: one about what the change does, and one that needs code outside
  the diff.
- **Reference.** Opus 5.5 at `high`.
- **Judge.** Opus 5.5 at `high` saw the anonymous answers in random order and scored them against the rubric below.
  Sonnet 5.5 at `high` judged everything a second time, as a check on Opus favouring its own answers.

## Key lines

12 PRs, 108 runs. Score is the Opus judge's mean overall score, 1 to 5. Recall is the share of the reference's
lines that a configuration also picked, within 3 lines.

| Config | Score | Sonnet judge | Recall | Hard failures | Cost per call | p50 latency |
|---|---|---|---|---|---|---|
| Haiku `low` | 2.75 | 2.58 | 0.53 | 3/12 | $0.015 | 3.0 s |
| Haiku `medium` | 3.33 | 3.08 | 0.63 | 0/12 | $0.016 | 6.4 s |
| Haiku `high` | 3.67 | 3.50 | 0.66 | 1/12 | $0.018 | 18.4 s |
| Sonnet `low` | 3.83 | 3.67 | 0.66 | 4/12 | $0.110 | 5.3 s |
| Sonnet `medium` | 3.92 | 3.50 | 0.66 | 5/12 | $0.110 | 4.9 s |
| Sonnet `high` (today) | 3.75 | 3.50 | 0.68 | 1/12 | $0.115 | 5.3 s |
| Opus `low` | 3.83 | 3.25 | 0.82 | 1/12 | $0.219 | 6.5 s |
| Opus `medium` | 3.92 | 3.58 | 0.77 | 1/12 | $0.228 | 12.0 s |
| Opus `high` (reference) | 4.33 | 3.67 | 1.00 | 0/12 | $0.241 | 15.9 s |

- Every hard failure was a line outside the diff. The model picked a line from a `<code>` block, the context around a
  change, though the prompt forbids it. `keepReal` already drops such a line, so the phone shows one item fewer.
  There were no invalid answers, refusals or cut-off answers.
- Some lists named the same line twice. `keepReal` drops the copy, so this is not counted as a failure.
- The Sonnet judge scored Opus 5.5 `high` 0.66 lower than the Opus judge did. Under the Sonnet judge, Haiku `high` and
  every Sonnet and Opus configuration except Opus `low` came within 0.3 of the reference. So part of the Opus lead may
  be the judge preferring its own model's answers.
- Latency at `medium` and `high` is a little low: they ran after `low` on the same input and read it from the cache.

## Ask AI

6 PRs, 2 questions each, 108 answers. Score is the Opus judge's mean overall score, 1 to 5. Paths is the share of
file paths in the answers that exist in the repository at the PR's head. Cost is the session's list cost per
question, runtime included.

| Config | Score | Sonnet judge | Hard failures | Paths | Cost per question | p50 latency |
|---|---|---|---|---|---|---|
| Opus `high` (second run) | 4.58 | n/a | 0/12 | 81/82 | $0.189 | 36 s |
| Haiku `low` | 3.75 | 3.50 | 0/12 | 62/62 | $0.004 | 13 s |
| Haiku `medium` | 4.17 | 4.00 | 0/12 | 59/60 | $0.005 | 18 s |
| Haiku `high` | 4.33 | 4.08 | 0/12 | 67/68 | $0.007 | 27 s |
| Sonnet `low` | 3.58 | 3.58 | 0/12 | 38/38 | $0.032 | 13 s |
| Sonnet `medium` | 3.50 | 3.25 | 0/12 | 36/36 | $0.035 | 13 s |
| Sonnet `high` | 3.92 | 3.75 | 0/12 | 56/56 | $0.055 | 18 s |
| Opus `low` | 4.33 | 4.08 | 0/12 | 57/57 | $0.080 | 18 s |
| Opus `medium` | 4.33 | 4.42 | 0/12 | 78/80 | $0.139 | 31 s |
| Opus `high` (reference) | 5.00 | 5.00 | 0/12 | 81/84 | $0.187 | 34 s |

- The judge also saw the reference answer as the model answer, so it scored its own copy 5.00. The second Opus `high`
  run, judged blind, is the fair bar: 4.58.
- No session reached its budget, stopped on errors or gave no answer.
- Haiku answers were the shortest and scored best on brevity. Opus answers were the most thorough and the longest.
- Sonnet 5.5 scored below Haiku 5.5 at every effort level. It read less of the repository: 2.6 to 4.5 tool calls
  a question, against 3.3 to 7.5 for Haiku.

## Rubrics

The judge scored each item from 1 to 5.

Key lines:

- **Precision.** The share of items a careful senior reviewer would need to read first. Formatting, renames, imports,
  and tests that only mirror the code count against it.
- **Coverage.** Whether the list has the core logic, the riskiest spot and any real decision. Missing the most
  important line caps it at 2.
- **Why.** Whether each reason is one plain, correct sentence that says what to check, and does not restate the line.
- **Overall.** The list's use to a reviewer on a phone with a few minutes. A short list of strong items beats a long
  one with filler.

A hard failure is an invalid or cut-off answer, a refusal, an error, an empty list, or any line the diff does not show.
The eval script checked these. The judge did not.

Ask AI:

- **Correctness.** Whether its claims about the code are right, checked against the diff and the reference. Where the
  diff contradicts the reference, the diff wins. A confident wrong claim on the main point caps it at 2.
- **Grounding.** Whether it names real files, functions and lines, and says what it did not check.
- **Brevity.** Whether it answers in a few short paragraphs a reviewer can read on a phone.
- **Overall.** The answer's use to a reviewer deciding what to do about the PR.

A hard failure is a session that gave no answer, reached its budget, stopped on errors or ended.

## PRs

Twelve real PRs: six for both jobs and six more for key lines alone, in TypeScript, Go, PHP, Python, Terraform, Swift,
config and CI, and Markdown, from 3 to 2,400 changed lines. The inputs ran from 3,000 to 159,000 tokens. The PRs and
the raw answers are not published; this page keeps the aggregate scores.

## Cost

The whole eval cost $20.68: $6.79 for key lines, $8.80 for Ask AI sessions, the second Opus run included,
and $5.09 for the judges.
