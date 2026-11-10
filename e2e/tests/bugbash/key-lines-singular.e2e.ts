import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

// PRDiffPage.swift: "\(items.count) key lines" has no singular.
test('one key line is counted as "1 key line"', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "Rate-limit the password reset endpoint" from the PRs list');
  await agent.act('open its Files changed page');
  await agent.assert('the key-line count in the toolbar reads "1 key line", not "1 key lines"');
});
