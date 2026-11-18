// `node:sqlite` in memory behind the slice of a Durable Object's `SqlStorage` that the limit counter uses: the counter's
// real SQL runs in tests.
import { DatabaseSync } from "node:sqlite";
import type { LimitSql } from "../../src/limit-counter.ts";

const databases = new Set<DatabaseSync>();

/** Close every SQLite fixture owned by the completed test, including failed tests. */
export function closeMemorySql(): void {
  for (const database of databases) {
    database.close();
    databases.delete(database);
  }
}

export function memorySql(): LimitSql {
  const database = new DatabaseSync(":memory:");
  databases.add(database);
  return {
    exec<Row>(query: string, ...bindings: unknown[]) {
      const rows = database
        .prepare(query)
        .all(...(bindings as (string | number | null)[])) as Row[];
      return { toArray: () => rows.map((row) => ({ ...row })) };
    },
  };
}
