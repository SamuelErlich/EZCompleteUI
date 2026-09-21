import { authContext, bodyObject, json, options, serviceClient } from "../_shared/http.ts";
Deno.serve(async req => {
  const preflight=options(req); if(preflight)return preflight;
  if(req.method!=="POST")return json({error:"method_not_allowed"},405);
  const auth=await authContext(req); if(auth instanceof Response)return auth;
  const body=bodyObject(await req.json().catch(()=>({}))); const messages=Array.isArray(body.messages)?body.messages:[];
  const latest=[...messages].reverse().find(x=>x&&typeof x==="object"&&(x as Record<string,unknown>).role==="user") as Record<string,unknown>|undefined;
  const content=typeof latest?.content==="string"?latest.content.trim():"";
  const model=typeof body.model==="string"?body.model:"beta";
  const logID=typeof body.usage_log_id==="string"?body.usage_log_id:"";
  if(!logID)return json({error:"usage_log_id_required"},400);
  if(Deno.env.get("OPENAI_API_KEY")) return json({error:"provider_adapter_pending"},503);
  const suffix=content?"\\n\\nVocê escreveu: “"+content.slice(0,240)+"”":"";
  const {data,error}=await serviceClient().rpc("ez_finish_beta_usage",{p_user_id:auth.user.id,p_log_id:logID,p_reply:"Modo beta ativo. O backend está autenticado e o consumo de créditos foi registrado. Modelo solicitado: "+model+"."+suffix});
  if(error)return json({error:error.message},400); return json(data||{error:"beta_response_unavailable"});
});
