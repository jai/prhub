// Every runtime test: a request to anywhere outside the Worker fails the test, and each test starts on empty storage.
import { reset } from "cloudflare:test";
import { setupNetwork } from "@msw/cloudflare";
import { http } from "msw";
import { afterAll, afterEach, beforeAll, expect } from "vitest";

const network = setupNetwork();
const unexpectedRequests: string[] = [];
beforeAll(() => {
  network.use(
    http.all("*", ({ request }) => {
      const call = `${request.method} ${request.url}`;
      unexpectedRequests.push(call);
      throw new Error(`Unexpected outbound request: ${call}`);
    }),
  );
  network.enable();
});
afterAll(() => network.disable());
afterEach(async () => {
  try {
    expect(unexpectedRequests).toEqual([]);
  } finally {
    unexpectedRequests.length = 0;
    await reset();
  }
});
