import { z } from "zod";
import { checkLinearKey } from "./tickets.ts";
import { bodyOf } from "./boundary.ts";
import { sessionOf, type HostedServices } from "./hosted.ts";

export async function linearKeyRoute(request: Request, services: HostedServices): Promise<Response> {
  const error = (status: number, code: string, message: string) =>
    Response.json({ error: { code, message } }, { status, headers: { "Cache-Control": "no-store" } });
  const session = await sessionOf(request, services);
  if (!session || session.state !== "signed_in") {
    return error(401, "signed_out", "Sign in with GitHub again");
  }
  let key: string | null = null;
  if (request.method === "PUT") {
    const body = z.object({ key: z.string().trim().regex(/^[A-Za-z0-9_-]{20,300}$/) })
      .safeParse((await bodyOf(request))?.value);
    if (!body.success) {
      return error(400, "linear_key_malformed", "Paste the whole Linear API key");
    }
    key = body.data.key;
    const checked = await checkLinearKey(key, services.fetch);
    if (checked === "invalid") {
      return error(422, "linear_key_invalid", "Linear did not accept this key");
    }
    if (checked === "unavailable") {
      return error(503, "linear_unavailable", "Linear could not be reached; try again");
    }
  }
  if (!await services.account(session.userId).setLinearKey(key)) {
    return error(401, "signed_out", "Sign in with GitHub again");
  }
  await services.index(session.userId).linearChanged();
  return Response.json({ linear_key: key !== null }, { headers: { "Cache-Control": "no-store" } });
}
