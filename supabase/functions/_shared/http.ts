import { createClient, SupabaseClient, User } from "https://esm.sh/@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function options(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response("ok", { headers: corsHeaders }) : null;
}

export function bearer(req: Request): string | null {
  const value = req.headers.get("authorization") || "";
  return value.toLowerCase().startsWith("bearer ") ? value.slice(7).trim() : null;
}

export async function authContext(req: Request): Promise<{ token: string; user: User; client: SupabaseClient } | Response> {
  const token = bearer(req);
  if (!token) return json({ error: "not_authenticated" }, 401);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) return json({ error: "backend_not_configured" }, 503);
  const client = createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: "Bearer " + token } },
  });
  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user) return json({ error: "invalid_session" }, 401);
  return { token, user: data.user, client };
}

export function serviceClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("service_role_not_configured");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export function bodyObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

export function idempotencyKey(req: Request, body: Record<string, unknown>): string {
  const header = req.headers.get("x-idempotency-key")?.trim();
  const bodyKey = typeof body.idempotency_key === "string" ? body.idempotency_key.trim() : "";
  const key = header || bodyKey;
  return key && key.length >= 16 && key.length <= 200 ? key : crypto.randomUUID();
}
