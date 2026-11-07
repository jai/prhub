// `node:sqlite` in memory behind the slice of a Durable Object's `SqlStorage` that the limit counter uses: the counter's
// real SQL runs in tests.
import { DatabaseSync } from "node:sqlite";
import type { LimitSql } from "../src/limit-counter.ts";

export function memorySql(): LimitSql {
  const database = new DatabaseSync(":memory:");
  return {
    exec<Row>(query: string, ...bindings: unknown[]) {
      const rows = database.prepare(query).all(...bindings as (string | number | null)[]) as Row[];
      return { toArray: () => rows.map((row) => ({ ...row })) };
    },
  };
}
