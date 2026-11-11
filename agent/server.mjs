// The AI container (docs/api.md, "AI on a subscription"): Claude Agent SDK runs, signed in with the Worker's
// CLAUDE_CODE_OAUTH_TOKEN. The Worker is its only caller; nothing here reaches R2 or keeps state between runs.
import { createServer } from "node:http";
import { InMemorySessionStore, query } from "@anthropic-ai/claude-agent-sdk";

const PORT = 8080;

/** One structured answer: `{system, prompt, model, effort, schema}` in, the parsed output and what it spent out. */
async function run({ system, prompt, model, effort, schema }) {
  let result = null;
  for await (const message of query({
    prompt,
    options: {
      systemPrompt: system, model, effort, tools: [], settingSources: [], maxTurns: 3,
      sessionStore: new InMemorySessionStore(), outputFormat: { type: "json_schema", schema },
    },
  })) {
    if (message.type === "result") {
      result = message;
    }
  }
  if (!result) {
    throw new Error("The agent ended without a result.");
  }
  const usage = result.usage ?? {};
  return {
    subtype: result.subtype,
    output: result.structured_output ?? null,
    model: Object.keys(result.modelUsage ?? {})[0] ?? model,
    tokens: {
      input: (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0),
      output: usage.output_tokens ?? 0,
    },
    costUsd: result.total_cost_usd ?? null,
  };
}

createServer(async (request, response) => {
  response.setHeader("content-type", "application/json");
  if (request.method === "GET" && request.url === "/health") {
    response.end('{"ok":true}');
    return;
  }
  if (request.method !== "POST" || request.url !== "/run") {
    response.statusCode = 404;
    response.end('{"error":"not found"}');
    return;
  }
  let body = "";
  for await (const chunk of request) {
    body += chunk;
  }
  try {
    response.end(JSON.stringify(await run(JSON.parse(body))));
  } catch (error) {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: String(error instanceof Error ? error.message : error) }));
  }
}).listen(PORT);
