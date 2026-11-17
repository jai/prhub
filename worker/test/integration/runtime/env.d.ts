import type { Env as WorkerEnv } from "../../../src/env.ts";

declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {}
    interface GlobalProps {
      mainModule: typeof import("../../../src/index.ts");
    }
  }
}
