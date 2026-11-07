// Makes the agent, environment and vault behind Ask AI, once, in the Anthropic org whose API key is in ANTHROPIC_API_KEY.
// Their ids go in the Worker's vars (ASK_AGENT_ID, ASK_ENVIRONMENT_ID, ASK_VAULT_ID, ASK_CREDENTIAL_ID); the key itself
// is the Worker's ASK_ANTHROPIC_API_KEY, or its ANTHROPIC_API_KEY when that is the same key.
//
//   node --experimental-strip-types worker/scripts/ask-agent.mts [--login <github login>]
//
// The agent is told whose review it helps: --login, else the user of GITHUB_TOKEN when that is set. Creates resources
// every run, so run it once per Worker and keep what it prints.
import { createAskResources } from "../src/ask-setup.ts";

async function reviewerLogin(): Promise<string | null> {
  const flag = process.argv.indexOf("--login");
  if (flag !== -1) {
    const login = process.argv[flag + 1];
    if (!login || !/^[A-Za-z0-9-]{1,39}$/.test(login)) {
      console.error("--login needs a GitHub login");
      process.exit(2);
    }
    return login;
  }
  if (!process.env.GITHUB_TOKEN) {
    return null;
  }
  const response = await fetch("https://api.github.com/user", {
    headers: { Authorization: `Bearer ${process.env.GITHUB_TOKEN}`, "User-Agent": "pr-viewer" },
  });
  if (!response.ok) {
    console.error(`GitHub answered ${response.status} for GITHUB_TOKEN's user; pass --login instead`);
    process.exit(1);
  }
  return ((await response.json()) as { login: string }).login;
}

if (!process.env.ANTHROPIC_API_KEY) {
  console.error("ANTHROPIC_API_KEY is not set");
  process.exit(2);
}
const login = await reviewerLogin();
const resources = await createAskResources(process.env.ANTHROPIC_API_KEY, login);
console.log(JSON.stringify({
  ASK_AGENT_ID: resources.agent_id, ASK_ENVIRONMENT_ID: resources.environment_id, ASK_VAULT_ID: resources.vault_id,
  ASK_CREDENTIAL_ID: resources.credential_id,
}));
