// Every integration-node test closes the SQLite databases it opened, failed tests included.
import { afterEach } from "vitest";
import { closeMemorySql } from "./memory-sql.ts";

afterEach(closeMemorySql);
