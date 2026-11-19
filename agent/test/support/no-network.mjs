// Node's fetch goes through undici's global dispatcher: with this one, a request no test stubbed fails at once
// instead of reaching the internet, and a stub a test set up but never used fails that test. Loopback stays open
// for the server test, which talks to the agent it started.
import { MockAgent, setGlobalDispatcher } from "undici";
import { afterEach, vi } from "vitest";

const network = new MockAgent();
network.disableNetConnect();
network.enableNetConnect(/^127\.0\.0\.1:\d+$/);
setGlobalDispatcher(network);

afterEach(() => {
  network.assertNoPendingInterceptors();
  vi.useRealTimers();
});
