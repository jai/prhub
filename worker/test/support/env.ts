import type { Env } from "../../src/env.ts";

/** A Worker env holding only `vars`: the variables and bindings the code under test reads. */
export const env = (vars: Partial<Env> = {}) => vars as Env;
