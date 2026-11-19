import { defineConfig } from "vitest/config";

// Every project runs its files in a random order, blocks the network, and undoes stubbed globals and mocks.
const shared = {
  environment: "node",
  sequence: { shuffle: true },
  unstubGlobals: true,
  restoreMocks: true,
  setupFiles: ["test/support/no-network.mjs"],
};

export default defineConfig({
  test: {
    projects: [
      // The vetting rules alone: nothing on disk, no processes.
      { test: { ...shared, name: "unit", include: ["test/unit/**/*.test.mjs"] } },
      // Real git in temporary folders, and the server as its own process.
      { test: { ...shared, name: "integration", include: ["test/integration/**/*.test.mjs"] } },
    ],
  },
});
