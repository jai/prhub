// The container's own process: it stops when the Worker asks it to.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";

const PORT = 18_000 + (process.pid % 1000);

async function started() {
  const server = spawn(process.execPath, ["server.mjs"], { env: { ...process.env, PORT: String(PORT) }, stdio: "ignore" });
  for (let tries = 0; tries < 100; tries++) {
    try {
      if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) {
        return server;
      }
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  server.kill("SIGKILL");
  throw new Error("the server did not start");
}

// 2026-11-14: as the container's first process it ignored SIGTERM, never slept, and kept a replaced token for a day.
// A handler is what a first process needs; here, where the signal would kill it anyway, the handler shows as exit 0.
test("an idle server leaves on SIGTERM, by its own exit", async () => {
  const server = await started();
  server.kill("SIGTERM");
  const [code, signal] = await once(server, "exit");
  assert.deepEqual({ code, signal }, { code: 0, signal: null });
});

test("a stop asked for during a request waits for its answer", async () => {
  const server = await started();
  // A body that never ends holds the request in flight.
  const { request } = await import("node:http");
  const held = request({ host: "127.0.0.1", port: PORT, path: "/run", method: "POST" });
  held.on("error", () => {});
  held.write("{");
  await new Promise((resolve) => setTimeout(resolve, 300));
  server.kill("SIGTERM");
  const left = once(server, "exit");
  const early = await Promise.race([left, new Promise((resolve) => setTimeout(() => resolve("waiting"), 500))]);
  assert.equal(early, "waiting", "it left with a request in flight");
  const answered = once(held, "response");
  held.end('"not an object"');
  const [response] = await answered;
  response.resume();
  const [code, signal] = await left;
  assert.deepEqual({ code, signal }, { code: 0, signal: null });
});
