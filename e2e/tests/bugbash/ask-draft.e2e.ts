import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

test('an unsent Ask AI draft survives a visit to another PR', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "Show a retry button when checkout fails" and open Ask AI');
  await agent.act('type "kiwi draft about retries" in the question field without sending it, then close Ask AI');
  await agent.act('go back to the PRs list, open another PR, then go back and open "Show a retry button when checkout fails" again');
  await agent.act('open Ask AI');
  await agent.assert('the question field still holds "kiwi draft about retries"');
});

// PRSession.openAsk sets the line anchor and keeps the draft written for the whole PR.
test('a whole-PR draft does not become a question about a line', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "fix: Keep the cart when the app is closed" and open Ask AI about the whole PR');
  await agent.act('type "whole PR draft" in the question field without sending it, then close Ask AI');
  await agent.act('open Files changed and open Ask AI on a changed line in src/cart/store.ts');
  await agent.assert('the sheet does not show "whole PR draft" as a question about that line');
});
