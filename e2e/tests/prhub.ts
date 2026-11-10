import { modes } from '../e2e.config.ts';

export const bundleId = 'com.jaigovindani.prreview';

/** Launches PRHub fresh in one of its Debug modes, whichever target the test runs on. */
export async function launch(
  device: { openApp(app: string, options: { relaunch: boolean; launchArguments: string[] }): Promise<unknown> },
  mode: keyof typeof modes,
): Promise<void> {
  await device.openApp(bundleId, { relaunch: true, launchArguments: [...modes[mode]] });
}
