import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

// PRHubHost.swift: the empty hint always says no PRs "are open", whatever the filter.
test('an empty Merged list does not talk about open PRs', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'hostedempty');
  await agent.act('on the PRs tab, open the filter, select Merged, and close the filter');
  await agent.assert('the empty list\'s message does not say that none of your pull requests "are open"', { vision: true });
});

test('with Merged chosen, only Merged is announced as selected', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'hostedempty');
  await agent.act('on the PRs tab, open the filter, select Merged, close the filter and open it again');
  await agent.assert('in the accessibility tree of the filter, Merged is marked selected and Open is not');
});
