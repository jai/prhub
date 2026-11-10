import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

// PRSampleSet.applying stores reviews and comments only: a line comment is said to be posted and then dropped.
test('a line comment shows on its line after Comment now', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "docs: Explain the local setup" and open its Files changed page');
  await agent.act('comment "Could we clarify this setup step?" on the added line "1. npm install" with Comment now');
  await agent.assert('the comment "Could we clarify this setup step?" shows in the diff under that line');
});

test('an edited description is kept after Save', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "fix: Keep the cart when the app is closed" and tap Edit description');
  await agent.act('add the sentence "violet otter note." at the end of the description and tap Save');
  await agent.assert('the PR description shows "violet otter note."');
});
