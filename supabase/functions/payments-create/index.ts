import { authContext, bodyObject, idempotencyKey, json, options } from "../_shared/http.ts";

// Real checkout is intentionally off until the merchant accounts, return URLs
// and server-side provider secrets have been configured and audited.
Deno.serve(async (req) => {
  const preflight = options(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = await authContext(req);
  if (auth instanceof Response) return auth;
  const body = bodyObject(await req.json().catch(() => ({})));
  const key = idempotencyKey(req, body);
  if (Deno.env.get("PAYMENTS_ENABLED") !== "true") {
    return json({ error: "payments_disabled_in_beta", idempotency_key: key }, 403);
  }
  return json({ error: "provider_adapter_pending", idempotency_key: key }, 501);
});
