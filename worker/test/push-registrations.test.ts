import assert from "node:assert/strict";
import { test } from "node:test";
import type { DeviceToken, Fingerprint } from "../src/ids.ts";
import {
  createPushRegistrationsTable, forgetPushTokensOf, pruneUnlinkedPushTokens, registerPushToken,
} from "../src/push-registrations.ts";
import { memorySql } from "./memory-sql.ts";

const PHONE = "a".repeat(64) as Fingerprint;
const IPAD = "b".repeat(64) as Fingerprint;
const token = (digit: string) => digit.repeat(64) as DeviceToken;

function registered(sql: ReturnType<typeof memorySql>) {
  return sql.exec<{ token: string; fingerprint: string | null }>(
    "SELECT token, fingerprint FROM devices ORDER BY token").toArray();
}

test("unpairing one device takes its push registrations and leaves the other device's", () => {
  const sql = memorySql();
  createPushRegistrationsTable(sql);
  registerPushToken(sql, token("1"), "production", PHONE);
  registerPushToken(sql, token("2"), "production", IPAD);
  assert.equal(forgetPushTokensOf(sql, PHONE), 1);
  assert.deepEqual(registered(sql), [{ token: token("2"), fingerprint: IPAD }]);
  assert.equal(forgetPushTokensOf(sql, PHONE), 0);
});

test("a token registered again belongs to the device that sent it last", () => {
  const sql = memorySql();
  createPushRegistrationsTable(sql);
  registerPushToken(sql, token("1"), "sandbox", PHONE);
  registerPushToken(sql, token("1"), "production", IPAD);
  assert.equal(forgetPushTokensOf(sql, PHONE), 0);
  assert.deepEqual(registered(sql), [{ token: token("1"), fingerprint: IPAD }]);
});

test("the cleanup removes registrations kept before devices were recorded and those of devices gone", () => {
  const sql = memorySql();
  sql.exec("CREATE TABLE devices (token TEXT PRIMARY KEY, host TEXT)");
  sql.exec("INSERT INTO devices (token, host) VALUES (?, ?)", token("0"), "production");
  createPushRegistrationsTable(sql);
  createPushRegistrationsTable(sql);
  registerPushToken(sql, token("1"), "production", PHONE);
  registerPushToken(sql, token("2"), "sandbox", IPAD);
  assert.deepEqual(pruneUnlinkedPushTokens(sql, new Set([IPAD])), [
    { token: "00000000", host: "production", reason: "unlinked" },
    { token: "11111111", host: "production", reason: "not_live" },
  ]);
  assert.deepEqual(registered(sql), [{ token: token("2"), fingerprint: IPAD }]);
});
