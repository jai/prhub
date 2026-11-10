import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import type { E2EConfig } from 'e2e';
import { mobile } from '@e2e-dev/mobile';
import { openai } from '@ai-sdk/openai';
import { chatgpt } from 'e2e/oauth/chatgpt';

// The ChatGPT (Codex) sign-in from `npx e2e login openai` when present, else OPENAI_API_KEY; E2E_PROVIDER=api forces the key.
const modelId = process.env.E2E_MODEL ?? 'gpt-6.1-terra';
const signedIn = process.env.E2E_PROVIDER !== 'api' && existsSync(path.join(process.env.XDG_CONFIG_HOME ?? path.join(homedir(), '.config'), 'e2e', 'oauth.json'));
const model = signedIn ? chatgpt(modelId) : openai(modelId);

// The Debug build's launch modes (app/PRHub/Debug/PRHubScreenshots.swift). None needs a Worker or reaches GitHub.
export const modes = {
  // Signed in as if paired, over the sample PRs, every AI feature on.
  paired: ['-PRHubPaired'],
  // A new phone: onboarding, then Sign in with GitHub against a fake hosted Worker.
  firstrun: ['-PRHubFirstRun'],
  // Signed in on the fake hosted Worker.
  hosted: ['-PRHubHosted'],
  // Hosted, with an empty PR list.
  hostedempty: ['-PRHubHosted', '-PRHubHostedEmpty'],
  // Hosted, after GitHub signed the person out.
  signedout: ['-PRHubHosted', '-PRHubSignedOut'],
  // Onboarding where GitHub says the person cancelled Sign in with GitHub.
  signindenied: ['-PRHubFirstRun', '-PRHubSignInDenied'],
} as const;

/** The QA agent every test and charter starts from. */
export const qa = {
  model,
  system: 'You are a thorough QA agent testing PRHub, an iPhone app for reviewing GitHub pull requests. Verify every outcome on screen.',
  context:
    'Every PR on screen is a made-up sample (orgs such as acme and octocat); a write stays on the phone and the app says nothing reached GitHub. ' +
    'Tabs: PRs and Settings. A PR opens on its page with description, checks, key lines and Ask AI; its diff is a separate page.',
};

// One simulator per parallel explorer: `PRHub E2E 1` … `PRHub E2E 4` (scripts in e2e/README.md).
const devices = (process.env.PRHUB_E2E_SIMS ?? '').split(',').filter(Boolean);

export default {
  agents: { default: qa },
  targets: devices.length === 0
    ? Object.entries(modes).map(([mode, launchArguments]) => ({
        name: mode,
        engine: mobile({ platform: 'ios' }),
        app: { bundleId: 'com.jaigovindani.prreview', launchArguments: [...launchArguments], identity: mode },
      }))
    : devices.flatMap((device, index) =>
        Object.entries(modes).map(([mode, launchArguments]) => ({
          name: `${mode}-${index + 1}`,
          engine: mobile({ platform: 'ios', device }),
          app: { bundleId: 'com.jaigovindani.prreview', launchArguments: [...launchArguments], identity: mode },
        })),
      ),
  workers: 1,
} satisfies E2EConfig;
