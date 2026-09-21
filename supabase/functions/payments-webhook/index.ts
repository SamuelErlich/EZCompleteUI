import { bodyObject, json, options, serviceClient } from "../_shared/http.ts";

// The webhook endpoint never trusts a client-supplied "approved" flag. In the
// future this handler must verify PayPal transmission headers or Mercado Pago
// x-signature by calling the provider API before invoking the RPC.
Deno.serve(async (req) => {
  const preflight = options(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (Deno.env.get("PAYMENTS_ENABLED") !== "true") return json({ error: "payments_disabled_in_beta" }, 403);
  const body = bodyObject(await req.json().catch(() => ({})));
  const provider = req.headers.get("x-payment-provider") || "";
  const eventID = req.headers.get("x-payment-event-id") || "";
  if (!provider || !eventID) return json({ error: "provider_signature_verification_required" }, 400);
  // Fail closed until the provider-specific verification adapter is installed.
  return json({ error: "provider_signature_verification_required" }, 501);
});
