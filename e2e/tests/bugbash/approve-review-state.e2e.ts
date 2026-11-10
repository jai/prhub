import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

// PRSampleSet.applying adds the review but leaves reviewDecision and the reviewer requests as they were.
test('approving a PR shows it as approved', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "Show a retry button when checkout fails" from the PRs list');
  await agent.act('approve the PR with the note "LGTM"');
  await agent.act('go back to the PRs list');
  await agent.assert('the row for "Show a retry button when checkout fails" says Approved and no longer says Needs review');
});

test('requesting changes replaces the earlier approval', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "docs: Explain the local setup" from the PRs list');
  await agent.act('request changes with the note "Please add a test for the failure case."');
  await agent.assert('the PR page status says Changes requested, not Approved');
});
