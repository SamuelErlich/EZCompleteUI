import { authContext, json, options } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const preflight = options(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  const auth = await authContext(req);
  if (auth instanceof Response) return auth;
  const url = new URL(req.url);
  const page = Math.max(0, Number(url.searchParams.get("page") || "0") || 0);
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") || "50") || 50));
  const from = page * limit;
  const { data: rawRows, error } = await auth.client
    .from("usage_log")
    // Keep this projection aligned with the beta migration. Additional
    // presentation fields are stored inside the immutable response JSON until
    // the provider-backed ledger schema is introduced.
    .select("id,feature,model,charged_credits,response,created_at")
    .order("created_at", { ascending: false })
    .range(from, from + limit - 1);
  if (error) return json({ error: error.message }, 400);
  const { data: wallet } = await auth.client.rpc("ez_wallet_snapshot");
  const balance = wallet?.balance || 0;
  const rows = (rawRows || []).map((row) => {
    const response = row.response && typeof row.response === "object" && !Array.isArray(row.response)
      ? row.response as Record<string, unknown>
      : {};
    const metadata = response.metadata && typeof response.metadata === "object" && !Array.isArray(response.metadata)
      ? response.metadata as Record<string, unknown>
      : {};
    const failed = response.completed === false;
    const refunded = response.refunded === true;
    const status = refunded
      ? "refunded"
      : failed
        ? "error"
        : (response.completed === true || response.pending === false ? "completed" : "pending");
    return {
      id: row.id,
      feature: row.feature,
      model: row.model,
      charged_credits: row.charged_credits,
      status,
      metadata,
      created_at: row.created_at,
      coins_charged: row.charged_credits,
      quantity: metadata.quantity || 1,
      prompt: metadata.prompt_preview || "",
      direction: "debit",
      running_balance: balance,
      images_returned: metadata.images_returned || 0,
      total_tokens: metadata.total_tokens || 0,
      error_text: metadata.error || "",
    };
  });
  return json({ rows, balance, has_more: rows.length === limit });
});
