import { authContext, bodyObject, idempotencyKey, json, options, serviceClient } from "../_shared/http.ts";
function n(v: unknown, fallback=0) { return typeof v === "number" && Number.isFinite(v) ? Math.floor(v) : fallback; }
async function hashFor(body: Record<string,unknown>) {
  const digest=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(JSON.stringify(body)));
  return Array.from(new Uint8Array(digest)).map(v=>v.toString(16).padStart(2,"0")).join("");
}
function costFor(body: Record<string,unknown>) {
  const f=String(body.feature||""); const q=Math.max(1,Math.min(n(body.quantity,1),20));
  // Closed-beta chat has a single predictable price. Provider/token pricing is
  // intentionally deferred until a real server adapter is reviewed.
  if (f.startsWith("chat_")) return 1;
  let base=f.includes("image_high")||f.includes("dalle3_hd")?35:f.includes("image")?20:f.includes("tts")?5:f.includes("voice")?40:f.includes("whisper")?8:f.includes("sora")?60:1;
  return Math.max(1,base*q);
}
Deno.serve(async req => {
  const preflight=options(req); if(preflight)return preflight;
  if(req.method!=="POST")return json({error:"method_not_allowed"},405);
  const auth=await authContext(req); if(auth instanceof Response)return auth;
  const body=bodyObject(await req.json().catch(()=>({}))); const key=idempotencyKey(req,body);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(key)) {
    return json({error:"idempotency_key_must_be_uuid"},400);
  }
  // The closed beta only has the deterministic chat adapter.  Refuse other
  // features before touching the wallet, so an unfinished provider can never
  // consume test credits and then fail with a 404/503.
  const feature = String(body.feature || "unknown");
  if (!feature.startsWith("chat_")) {
    const { data: wallet } = await serviceClient().from("wallets")
      .select("balance").eq("user_id", auth.user.id).maybeSingle();
    return json({allowed:false,balance:wallet?.balance ?? 0,
      reason:"feature_not_enabled_in_beta"},403);
  }
  const {data,error}=await serviceClient().rpc("ez_charge_usage",{
    p_user_id:auth.user.id,p_feature:feature,
    p_model:typeof body.model==="string"?body.model:"beta-demo",p_cost:costFor(body),
    p_idempotency_key:key,p_request_hash:await hashFor(body)
  });
  if(error)return json({error:error.message},400); return json(data||{allowed:false,balance:0,reason:"Servidor indisponível"});
});
