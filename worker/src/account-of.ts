// A person's account object, reached from anywhere a request acts for them, without loading the hosted routes.
import type { AccountCore } from "./account-core.ts";
import { type Env, isSet } from "./env.ts";

export type AccountApi = Pick<
  AccountCore,
  | "signIn"
  | "finish"
  | "session"
  | "accessToken"
  | "tokenAfterUnauthorized"
  | "signOutEverywhere"
  | "signOut"
  | "deleteAccount"
  | "setAnthropicKey"
  | "setLinearKey"
  | "linearCannotComment"
  | "installationIds"
  | "claimInstallationSync"
  | "setInstallations"
  | "installationAccounts"
  | "installationSyncedAt"
>;

/** The Durable Object name of a person's account and PR index. */
export function userObjectName(userId: string): string {
  return `user:${userId}`;
}

export function accountOf(env: Env, userId: string): AccountApi {
  const namespace = env.USER_ACCOUNTS as DurableObjectNamespace;
  return namespace.get(namespace.idFromName(userObjectName(userId))) as unknown as AccountApi;
}

/**
 * GitHub answered 401 to a person's token: the account refreshes it (once, whatever else asks at the same time) and
 * the request goes again with the new one. Null when there is none: the person is signed out, or GitHub is away.
 */
export async function renewAfterUnauthorized(env: Env): Promise<string | null> {
  if (!isSet(env.SIGNED_IN_USER_ID) || env.USER_ACCOUNTS === undefined) {
    return null;
  }
  const answer = await accountOf(env, env.SIGNED_IN_USER_ID).tokenAfterUnauthorized(
    env.GITHUB_TOKEN,
  );
  if (answer.kind !== "ok") {
    return null;
  }
  env.GITHUB_TOKEN = answer.token;
  return answer.token;
}
