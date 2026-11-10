import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

test('a review indented four spaces renders as a code block', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "fix: Keep the cart when the app is closed" and tap Comment');
  await agent.act('enter {body} and submit the comment', { params: { body: '    indented review\n    second line' } });
  await agent.act('scroll until the body of the new conversation entry is on screen');
  await agent.assert('the new conversation entry shows "indented review" and "second line" on two lines in a code block', { vision: true });
});

test('the Request changes button stays reachable with the keyboard up', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'paired');
  await agent.act('open the PR "fix: Keep the cart when the app is closed" and tap Request changes');
  await agent.act('enter {body} in the review field, leaving the keyboard up', { params: { body: 'line one\nline two\nline three\nline four\nline five\nline six' } });
  await agent.assert('the button that submits the request for changes is visible above the keyboard', { vision: true });
});
