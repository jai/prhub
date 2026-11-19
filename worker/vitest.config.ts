import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Every project runs its files in a random order, and undoes stubbed globals and mocks after each test.
const shared = { sequence: { shuffle: true }, unstubGlobals: true, restoreMocks: true };

export default defineConfig({
  test: {
    projects: [
      {
        // Plain Node: `cloudflare:*` modules can't load, and the network is blocked.
        test: {
          ...shared,
          name: "unit",
          environment: "node",
          include: ["test/unit/**/*.test.ts"],
          setupFiles: ["test/support/no-network.ts"],
        },
      },
      {
        // Node with in-memory SQLite and fixture files; the network is blocked.
        test: {
          ...shared,
          name: "integration-node",
          environment: "node",
          include: ["test/integration/node/**/*.test.ts"],
          setupFiles: ["test/support/no-network.ts"],
        },
      },
      {
        // The real Worker runtime (workerd) with local bindings. No deployment credentials, services or containers.
        plugins: [
          cloudflareTest({
            main: "./src/index.ts",
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
          ...shared,
          name: "integration-runtime",
          include: ["test/integration/runtime/**/*.test.ts"],
        },
      },
    ],
  },
});
