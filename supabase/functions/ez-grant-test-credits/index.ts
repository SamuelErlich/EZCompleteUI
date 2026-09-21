import { authContext, bodyObject, json, options } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const preflight = options(req);
  if (preflight) return preflight;
  const auth = await authContext(req);
  if (auth instanceof Response) return auth;
  if (req.method === "GET") {
    const { data, error } = await auth.client.rpc("ez_test_grant_status");
    if (error) return json({ error: error.message }, 400);
    return json(data ?? { available: false, coins_to_award: 0, one_time: true });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const body = bodyObject(await req.json().catch(() => ({})));
  if (body.action === "status") {
    const { data, error } = await auth.client.rpc("ez_test_grant_status");
    if (error) return json({ error: error.message }, 400);
    return json(data ?? { available: false, claimed: false, coins_to_award: 0, one_time: true });
  }
  const grantKey = typeof body.grant_key === "string" ? body.grant_key.trim() : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(grantKey)) {
    return json({ error: "invalid_grant_key" }, 400);
  }
  const { data, error } = await auth.client.rpc("ez_grant_test_credits", { p_grant_key: grantKey });
  if (error) {
    const status = error.message.includes("disabled") ? 403 : 400;
    return json({ error: error.message }, status);
  }
  const result = bodyObject(data ?? {});
  return json({
    ...result,
    success: result.success === true,
    coins_added: result.credits_added || 0,
    next_claim_at: null,
  });
});
