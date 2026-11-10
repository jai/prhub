import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

// PRHubSamples.swift: a sample's reviewDecision is APPROVED or REVIEW_REQUIRED, never CHANGES_REQUESTED.
test('a PR with changes requested says so on its page too', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.assert('the PRs list row for "fix: Keep the cart when the app is closed" says Changes requested');
  await agent.act('open the PR "fix: Keep the cart when the app is closed"');
  await agent.assert('the PR page shows the review state as Changes requested, not Needs review');
});

test('a PR that needs no review does not say Needs review on its page', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open My PRs and open the PR "Add a fish shell prompt"');
  await agent.assert('the PR page does not say Needs review');
});
