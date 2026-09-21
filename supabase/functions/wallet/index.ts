import { authContext, json, options } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const preflight = options(req);
  if (preflight) return preflight;
  if (req.method !== "POST" && req.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  const auth = await authContext(req);
  if (auth instanceof Response) return auth;
  const { data, error } = await auth.client.rpc("ez_wallet_snapshot");
  if (error) return json({ error: error.message }, 400);
  return json(data ?? { balance: 0, tier: "beta", status: "active", has_ever_purchased: false });
});
