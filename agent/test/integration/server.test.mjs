// The container's own process: it stops when the Worker asks it to.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { onTestFinished, test } from "vitest";

async function started() {
  const root = mkdtempSync(`${tmpdir()}/prhub-agent-server-`);
  const server = spawn(process.execPath, [new URL("../../server.mjs", import.meta.url).pathname], {
    cwd: root,
    env: { PATH: process.env.PATH, HOME: root, TMPDIR: root, PORT: "0" },
    stdio: ["ignore", "ignore", "pipe", "ipc"],
  });
  let stderr = "";
  server.stderr.setEncoding("utf8").on("data", (chunk) => {
    stderr += chunk;
  });
  const left = once(server, "exit");
  const closed = once(server, "close");
  onTestFinished(async () => {
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGKILL");
    }
    await closed;
    rmSync(root, { recursive: true, force: true });
  });
  const [ready] = await Promise.race([
    once(server, "message", { signal: AbortSignal.timeout(10_000) }),
    left.then(([code, signal]) => {
      throw new Error(`Agent exited before listening (${code ?? signal}): ${stderr}`);
    }),
  ]);
  assert.equal(ready.type, "listening");
  assert.ok(Number.isInteger(ready.port) && ready.port > 0);
  const health = await fetch(`http://127.0.0.1:${ready.port}/health`, {
    signal: AbortSignal.timeout(5_000),
  });
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true });
  return { server, port: ready.port, left };
}

// The signal handler distinguishes the container's intentional exit from a default signal death.
test("an idle server leaves on SIGTERM, by its own exit", { timeout: 15_000 }, async () => {
  const { server, left } = await started();
  server.kill("SIGTERM");
  const [code, signal] = await left;
  assert.deepEqual({ code, signal }, { code: 0, signal: null });
});

test("a stop asked for during a request waits for its answer", { timeout: 15_000 }, async () => {
  const { server, port, left } = await started();
  const held = request({
    host: "127.0.0.1",
    port,
    path: "/run",
    method: "POST",
    headers: { Expect: "100-continue" },
  });
  // once() rejects active waits on errors; this listener also handles cancellation during cleanup.
  held.on("error", () => {});
  onTestFinished(() => held.destroy());
  const accepted = once(held, "continue");
  held.flushHeaders();
  await accepted;
  // The server accepted the request headers; an unfinished body now holds it in flight.
  held.write("{");
  const leaving = once(server, "message");
  server.kill("SIGTERM");
  const [notice] = await leaving;
  assert.deepEqual(notice, { type: "leaving", inFlight: 1 });
  assert.equal(server.exitCode, null, "it left with a request in flight");
  const answered = once(held, "response");
  held.end('"not an object"');
  const [response] = await answered;
  assert.equal(response.statusCode, 400, "the malformed body is refused before shutdown");
  const chunks = [];
  for await (const chunk of response) {
    chunks.push(chunk);
  }
  assert.equal(typeof JSON.parse(Buffer.concat(chunks).toString()).error, "string");
  const [code, signal] = await left;
  assert.deepEqual({ code, signal }, { code: 0, signal: null });
});

test(
  "asked for progress, the server answers in lines, an error too",
  { timeout: 15_000 },
  async () => {
    const { port } = await started();
    const asked = (body) =>
      fetch(`http://127.0.0.1:${port}/ask`, { method: "POST", body: JSON.stringify(body) });
    const lines = await asked({ progress: true });
    assert.equal(lines.headers.get("content-type"), "application/x-ndjson");
    assert.equal(typeof (await lines.json()).error, "string");
    const reply = await fetch(`http://127.0.0.1:${port}/reply`, {
      method: "POST",
      body: JSON.stringify({ id: "nobody-asked", text: "x", isError: false }),
    });
    assert.equal(reply.status, 404, "a reply to a question no turn asked settles nothing");
    assert.deepEqual(await reply.json(), { ok: false });
    const plain = await asked({});
    assert.equal(plain.headers.get("content-type"), "application/json");
    assert.equal(typeof (await plain.json()).error, "string");
  },
);
