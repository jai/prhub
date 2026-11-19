// The Agent SDK container's Durable Object binding (`AGENT`) in memory, as the Worker calls it.
import type { Env } from "../../src/env.ts";

/**
 * A container whose answer to each request is `answer(body, url)`. Every request's JSON body is kept in `sent`, and the
 * name of every instance the Worker opened in `instances`.
 */
export function fakeAgent<Body = Record<string, unknown>>(
  answer: (body: Body, url: string) => unknown,
) {
  const sent: Body[] = [];
  const instances: string[] = [];
  const binding = {
    idFromName: (name: string) => {
      instances.push(name);
      return name;
    },
    get: () => ({
      fetch: async (url: string, init: RequestInit) => {
        const body = JSON.parse(String(init.body)) as Body;
        sent.push(body);
        return Response.json(answer(body, url));
      },
    }),
  } as unknown as Env["AGENT"];
  return { binding, sent, instances };
}
