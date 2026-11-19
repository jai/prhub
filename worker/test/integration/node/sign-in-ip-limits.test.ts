// The hosted sign-in routes' per-IP limits on the real counter: each IP hash counted on its own SQLite, as an `IpLimit`
// object counts it, through `/auth/github/start` and `/finish`.
import assert from "node:assert/strict";
import { afterEach, test } from "vitest";
import { consumeLimits, createLimitHitsTable, type LimitSql } from "../../../src/limit-counter.ts";
import { hostedWorld, type LimitIp } from "../../support/hosted-world.ts";
import { closeMemorySql, memorySql } from "../../support/memory-sql.ts";

afterEach(closeMemorySql);

/** One SQLite counter per IP hash, as each IP gets its own `IpLimit` object. */
function sqliteIpLimits(): LimitIp {
  const counters = new Map<string, LimitSql>();
  return async (ipHash, checks, key, now) => {
    let sql = counters.get(ipHash);
    if (!sql) {
      sql = memorySql();
      createLimitHitsTable(sql);
      counters.set(ipHash, sql);
    }
    return consumeLimits(sql, checks, "", key, now);
  };
}

test("sign-in start and finish are limited per IP, each by its own LIMIT_ var, with the limit and wait named", async () => {
  const world = hostedWorld(
    {
      LIMIT_SIGN_IN_STARTS_PER_IP_PER_MINUTE: "2",
      LIMIT_SIGN_IN_FINISHES_PER_IP_PER_MINUTE: "3",
    },
    { limitIp: sqliteIpLimits() },
  );
  const start = (ip: string) =>
    world.route("/auth/github/start?state=x", { headers: { "CF-Connecting-IP": ip } });
  assert.equal((await start("203.0.113.1")).status, 400);
  assert.equal((await start("203.0.113.1")).status, 400);
  const third = await start("203.0.113.1");
  assert.equal(third.status, 429);
  assert.equal(third.headers.get("Retry-After"), "60");
  assert.deepEqual(((await third.json()) as { error: object }).error, {
    code: "limit_reached",
    message: "sign_in_starts_per_ip_per_minute reached; try again in 60 s",
    limit: "sign_in_starts_per_ip_per_minute",
    retry_after: 60,
  });
  assert.equal((await start("203.0.113.2")).status, 400, "another IP has its own count");
  const finish = () =>
    world.route("/auth/github/finish", {
      method: "POST",
      headers: { "CF-Connecting-IP": "203.0.113.1" },
    });
  for (let attempt = 0; attempt < 3; attempt += 1) {
    assert.equal((await finish()).status, 400);
  }
  assert.equal((await finish()).status, 429);
  assert.equal(world.pending.size, 0);
  world.clock.now += 60_000;
  assert.equal((await start("203.0.113.1")).status, 400, "the window passes");
  assert.ok(
    [...world.limitedIps].every((key) => /^[0-9a-f]{64}$/.test(key)),
    "an IP is counted by its hash",
  );
});
