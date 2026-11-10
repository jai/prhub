import type { E2EConfig } from 'e2e';
import base, { qa as entry } from './e2e.config.ts';

const shared: E2EConfig = base;

const context =
  `${entry.context} ` +
  'This is a Debug build on a fake Worker: no real GitHub, no push notifications, no camera for QR codes. ' +
  'Never open links that leave the app to Safari and judge the result; the browser is out of scope. ' +
  'Not bugs: the sample PRs and their made-up content; "Sample PR: this stays on your phone. Nothing was sent to GitHub." after a write; ' +
  'accessible text that splits around inline links (judge copy by the screenshot); content that loads after a scroll.';
const persona = { ...entry, maxSteps: 40, maxModelCalls: 40, context };

export default {
  ...shared,
  tests: ['tests/**/*.e2e.ts'],
  retries: 0,
  // Simulators answer slowly while several explore at once.
  actionTimeout: 60_000,
  // A repro walks several agent steps on a slow simulator.
  timeout: 300_000,
  reporters: ['list'],
  agents: {
    default: persona,
    newcomer: { ...persona, system: `${entry.system} You have never used this app. Follow only what the screens say; report anything confusing, a dead end, or a control that does nothing.` },
    skeptic: { ...persona, system: `${entry.system} Distrust every number, count, date, status and label on screen; cross-check each against every other place it appears (list row, PR page, diff, badges).` },
    fuzzer: { ...persona, system: `${entry.system} At every text input, run the charter's input matrix before anything else, judging each entry before the next. Never take the happy path.` },
    stateful: { ...persona, system: `${entry.system} After every change, leave the screen and come back, switch tabs, and relaunch the app; report state that is lost, stale, or duplicated.` },
  },
} satisfies E2EConfig;
