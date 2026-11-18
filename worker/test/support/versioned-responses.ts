import { VERSION_METADATA } from "../../src/versioned.ts";

interface Put {
  key: string;
  value: string;
  version: string | undefined;
}

/** An R2 bucket in memory: what was put, and with which version. */
export function fakeStore(held: Record<string, { body: string; version?: string }> = {}) {
  const puts: Put[] = [];
  const store = {
    puts,
    async get(key: string) {
      return held[key] ? { body: held[key].body } : null;
    },
    async head(key: string) {
      return held[key]
        ? { customMetadata: held[key].version ? { [VERSION_METADATA]: held[key].version } : {} }
        : null;
    },
    async put(
      key: string,
      value: ArrayBuffer | string,
      options?: { customMetadata?: Record<string, string> },
    ) {
      const text = typeof value === "string" ? value : new TextDecoder().decode(value);
      puts.push({ key, value: text, version: options?.customMetadata?.[VERSION_METADATA] });
      held[key] = { body: text, version: options?.customMetadata?.[VERSION_METADATA] };
      return null;
    },
  };
  return store;
}
/** GitHub with the PR at `head`: its diff, and its REST answer. Anything else asked for is recorded. */
export function gitHubAt(head: string, others: string[] = []): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    const accept = new Headers(init?.headers).get("Accept") ?? "";
    if (url === "https://api.github.com/repos/acme/app/pulls/7") {
      return accept.includes("diff")
        ? new Response("diff --git a/x b/x\n")
        : Response.json({ title: "T", body: "", head: { sha: head }, base: { ref: "main" } });
    }
    others.push(url);
    return new Response("not here", { status: 500 });
  }) as typeof fetch;
}
