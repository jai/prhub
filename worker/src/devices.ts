/** The routes a device calls about itself: push registration, what it did, and forgetting its pairing. */
import type { ApnsHost } from "./apns.ts";
import { bodyOf, parseDeviceEvent, parseDeviceRegistration } from "./boundary.ts";
import type { DeviceToken, Fingerprint } from "./ids.ts";
import { deviceSecretOf, fingerprintOf } from "./pairing.ts";

/** The part of the PR index these routes use; a test passes a fake. */
export interface DeviceIndex {
  registerDevice(token: DeviceToken, host: ApnsHost): unknown;
  record(kind: string, detail: { changed?: string[]; complete?: boolean } & Record<string, unknown>): unknown;
  unpair(fingerprint: Fingerprint): unknown;
}

function invalid(message: string): Response {
  return Response.json({ error: { code: "validation_error", message } }, { status: 400 });
}

/** `POST /device/register`. A token the relay would refuse on every push is refused here instead, and never kept. */
export async function registerRoute(request: Request, index: DeviceIndex): Promise<Response> {
  const device = parseDeviceRegistration((await bodyOf(request))?.value);
  if (!device) {
    return invalid("token must be the APNs device token in hex; host production or sandbox");
  }
  await index.registerDevice(device.token, device.host);
  return new Response(null, { status: 204 });
}

/** `POST /device/event`. */
export async function eventRoute(request: Request, index: DeviceIndex): Promise<Response> {
  const event = parseDeviceEvent((await bodyOf(request))?.value);
  if (!event) {
    return invalid("an event is an object with a kind; changed, when sent, a list of PR ids");
  }
  await index.record(event.kind, event.detail);
  return new Response(null, { status: 204 });
}

/** `DELETE /device/pair`: the bearer's secret stops working at once, on every isolate (`isPairedSecret`). */
export async function unpairRoute(request: Request, index: DeviceIndex): Promise<Response> {
  const secret = deviceSecretOf(request.headers.get("Authorization"));
  if (secret) {
    await index.unpair(await fingerprintOf(secret));
  }
  return new Response(null, { status: 204 });
}
