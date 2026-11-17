import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./src/index.ts",
      // Local bindings for the real production entrypoint. No deployment credentials, services or containers.
      miniflare: {
        compatibilityDate: "2026-09-01",
        bindings: {
          GITHUB_TOKEN: "test-github-token",
          GITHUB_LOGIN: "runtime-test",
          APP_TOKEN: "runtime-app-token",
          APP_LATEST_URL: "off",
        },
        r2Buckets: ["DIFFS"],
        durableObjects: {
          PR_INDEX: { className: "PrIndex", useSQLite: true },
          AI_JOBS: { className: "AiJobs", useSQLite: true },
          SIGN_INS: { className: "SignIn", useSQLite: true },
          IP_LIMITS: { className: "IpLimit", useSQLite: true },
        },
      },
    }),
  ],
  test: {
    include: ["test/integration/runtime/*.test.ts"],
  },
});
