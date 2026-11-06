# Push relay

Jai runs the relay as a Worker on his own Cloudflare account. The deployment guide gives its URL.

An APNs key works only for apps on its own Apple team. PRHub is on Jai's Apple team, so a Worker that
someone else deploys cannot push to it directly. It sends each push here instead, and the relay sends it to Apple with
Jai's APNs key. The relay keeps no message: it forwards and forgets.

## Keys

Each self-hosted Worker has one relay key, issued by Jai (or his agent) at setup.

- `POST /v1/keys` with `Authorization: Bearer <RELAY_ADMIN_TOKEN>` and `{"label": "<who it is for>"}` answers
  `201 {"key_id": "rk_…", "key": "rks_…"}`. The key is shown once; the relay stores only its SHA-256.
- `DELETE /v1/keys/{key_id}` (admin) revokes it: `204`, or `404` for a key that is unknown or already revoked.
- `GET /v1/keys` (admin) answers `200 {"keys": [{key_id, label, created_at, last_used_at, sent_24h}]}` for the live
  keys, without the keys themselves. `sent_24h` counts by the hour, so it covers 23 to 24 hours.
- Admin routes answer `401` for a missing or wrong admin token, and to everyone while `RELAY_ADMIN_TOKEN` is unset.

## Sending

`POST /v1/push` with `Authorization: Bearer <relay key>` and:

```json
{
  "device_token": "<hex APNs token>",
  "apns_env": "production" | "sandbox",
  "push_type": "alert" | "background",
  "priority": 5 | 10,
  "collapse_id": "<at most 64 bytes, optional>",
  "expiration": 1767225600,
  "payload": { "aps": { } }
}
```

- `device_token` is 2–200 hex characters, as `POST /device/register` accepts.
- `collapse_id` and `expiration` may be absent or `null` to send no `apns-collapse-id` or `apns-expiration` header.
  `expiration` is UNIX seconds.
- `payload` must have an `aps` object. Any field not listed above is refused.
- The topic is always the public app's bundle ID (`APNS_TOPIC`): a key cannot push to any other app.
- `payload` is at most 4096 bytes serialised, as APNs allows.

Answers:

- `200 {"apns_status": 200, "apns_id": "…", "reason": null}` when Apple took it.
- `200 {"apns_status": 410, "apns_id": "…", "reason": "Unregistered"}` and other APNs refusals are passed through
  with a `200` from the relay, so the Worker records them as it does a direct send (`PushResult` in
  `worker/src/apns.ts`).
- `200` with `apns_status: null` when the relay could not ask Apple: `reason` is `apns_not_configured`,
  `apns_key_invalid`, `fetch_error: timeout` or `fetch_error: network`.
- `400 {"error": "…"}` for a body that is not the shape above: `invalid_json`, `unknown_field`, `body_too_large`
  (over 16 KiB), `payload_too_large`, or `invalid_<field>`. `401` for a missing, unknown or revoked key, checked
  first. `429 {"error": "rate_limited", "retry_after": <seconds>}` past 600 pushes in the last hour or 60 in the
  current minute per key. A refused push does not count against the key.

## In the self-hosted Worker

`worker/src/apns.ts` sends through the relay when `PUSH_RELAY_URL` and the secret `PUSH_RELAY_KEY` are set, and
straight to APNs otherwise (Jai's own Worker). The rest of the Worker does not know which.

