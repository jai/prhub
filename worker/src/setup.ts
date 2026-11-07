import { type Env, githubLogin, isSet } from "./env.ts";

/**
 * Optional: a GitHub App that sends webhooks, for updates within seconds instead of the one-minute poll. Reads and writes
 * stay on `GITHUB_TOKEN`; the App only says when to look. GitHub's app-manifest flow makes it with one button, so nobody
 * copies a secret by hand. It is made on `GITHUB_APP_OWNER`, an org, or on the token's own user when that is unset, and
 * points at whatever origin this page was opened on.
 */
export function appManifest(origin: string, name: string): object {
  return {
    name,
    url: origin,
    hook_attributes: { url: `${origin}/github/webhook` },
    redirect_url: `${origin}/github/callback`,
    public: false,
    default_permissions: { metadata: "read", pull_requests: "read", issues: "read" },
    default_events: [
      "pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_review_thread",
      "issue_comment",
    ],
  };
}

/** Where the form goes: an org's new-App page, or the user's own. */
export function newAppUrl(owner: string | undefined, state: string): string {
  const base = isSet(owner) ? `https://github.com/organizations/${encodeURIComponent(owner)}/settings/apps/new`
    : "https://github.com/settings/apps/new";
  return `${base}?state=${encodeURIComponent(state)}`;
}

function isSetupRequest(params: URLSearchParams, env: Env): boolean {
  return isSet(env.SETUP_STATE) && params.get("state") === env.SETUP_STATE;
}

function escapeHtml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll("'", "&#39;")
    .replaceAll('"', "&quot;");
}

export async function createAppPage(request: Request, params: URLSearchParams, env: Env): Promise<Response> {
  if (!isSetupRequest(params, env)) {
    return new Response("not found\n", { status: 404 });
  }
  const origin = new URL(request.url).origin;
  const name = isSet(env.GITHUB_APP_NAME) ? env.GITHUB_APP_NAME : `${await githubLogin(env)}-pr-review`.slice(0, 34);
  const where = isSet(env.GITHUB_APP_OWNER) ? env.GITHUB_APP_OWNER : "your account";
  const manifest = escapeHtml(JSON.stringify(appManifest(origin, name)));
  return new Response(`<!doctype html><meta name="viewport" content="width=device-width">
    <form method="post" action="${escapeHtml(newAppUrl(env.GITHUB_APP_OWNER, env.SETUP_STATE ?? ""))}">
    <input type="hidden" name="manifest" value="${manifest}">
    <button style="font-size:20px;padding:16px">Create ${escapeHtml(name)} on ${escapeHtml(where)}</button></form>`,
  { headers: { "Content-Type": "text/html" } });
}

/** Keeps what GitHub returns until it is read once and set as Worker secrets (docs/api.md). */
export async function finishAppCreation(params: URLSearchParams, env: Env): Promise<Response> {
  const code = params.get("code");
  if (!isSetupRequest(params, env) || !code || !/^\w+$/.test(code)) {
    return new Response("not found\n", { status: 404 });
  }
  const response = await fetch(`https://api.github.com/app-manifests/${code}/conversions`, {
    method: "POST",
    headers: { Accept: "application/vnd.github+json", "User-Agent": "pr-viewer" },
  });
  if (!response.ok) {
    return new Response(`GitHub answered ${response.status}\n`, { status: 502 });
  }
  const app = await response.text();
  await env.DIFFS.put("setup/github-app.json", app);
  const { html_url: url } = JSON.parse(app) as { html_url: string };
  return Response.redirect(`${url}/installations/new`, 302);
}
