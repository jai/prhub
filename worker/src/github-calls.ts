import type { Env } from "./env.ts";

/** The GitHub calls a response cost, as `Server-Timing` (`github;desc="github calls";dur=<n>`), 304s included. */
export async function counted(env: Env, serve: (counting: Env) => Promise<Response>): Promise<Response> {
  const calls = { count: 0 };
  const response = await serve({ ...env, GITHUB_CALLS: calls });
  const headed = new Response(response.body, response);
  headed.headers.set("Server-Timing", `github;desc="github calls";dur=${calls.count}`);
  return headed;
}
