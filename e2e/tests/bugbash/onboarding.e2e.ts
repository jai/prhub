import { test } from '@e2e-dev/mobile';
import { launch } from '../prhub.ts';

test('Sign in with GitHub in sample Settings starts sign-in in one tap', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'firstrun');
  await agent.act('tap Try with sample PRs');
  await agent.act('open the Settings tab and tap Sign in with GitHub');
  await agent.assert('the app is signed in or shows GitHub sign-in, not the onboarding screen with another Sign in with GitHub button');
});

test('a cancelled sign-in keeps what was done to the sample PRs', { tags: ['bugbash'] }, async ({ device, agent }) => {
  await launch(device, 'signindenied');
  await agent.act('tap Try with sample PRs, open "fix: Keep the cart when the app is closed", and comment "otter comment"');
  await agent.act('open the Settings tab, tap Sign in with GitHub, and wait until Settings says the sign-in was not authorized');
  await agent.act('open the PRs tab');
  await agent.act('open "fix: Keep the cart when the app is closed" and scroll to the end of its Conversation');
  await agent.assert('the Conversation includes the comment "otter comment"', { vision: true });
});
