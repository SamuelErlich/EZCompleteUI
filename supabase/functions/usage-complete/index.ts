import { authContext, bodyObject, json, options, serviceClient } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const preflight = options(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = await authContext(req);
  if (auth instanceof Response) return auth;
  const body = bodyObject(await req.json().catch(() => ({})));
  const logId = typeof body.log_id === "string" ? body.log_id : "";
  if (!logId) return json({ error: "log_id_required" }, 400);
  const { data, error } = await serviceClient().rpc("ez_complete_usage", {
    p_user_id: auth.user.id,
    p_log_id: logId,
    p_success: body.success === true,
    p_metadata: { images_returned: body.images_returned || 0, error: body.error || null },
  });
  if (error) return json({ error: error.message }, 400);
  return json(data ?? { success: true });
});
