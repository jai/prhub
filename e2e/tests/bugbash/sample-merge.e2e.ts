import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

// PRSampleSet.applying stores reviews and comments only: a merge is never kept.
test('a merged PR stays merged when opened again', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open My PRs and open the PR "Add a fish shell prompt"');
  await agent.act('merge the PR and confirm');
  await agent.act('go back to the PRs list and open "Add a fish shell prompt" again');
  await agent.assert('the PR shows as merged and offers no Merge button');
});
