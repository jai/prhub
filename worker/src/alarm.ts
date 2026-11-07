/** An alarm this far past its time has stopped: Cloudflare gave up retrying it, and it will not fire. */
export const STALE_ALARM_MS = 60_000;

/**
 * The alarm to set for work wanted at `wanted`: none when one already fires by then, else `wanted`. One stuck in the
 * past is replaced, or the work behind it would wait for ever.
 */
export function alarmToSet(current: number | null, wanted: number, now: number): number | null {
  const live = current !== null && current >= now - STALE_ALARM_MS;
  return live && current <= wanted ? null : wanted;
}
