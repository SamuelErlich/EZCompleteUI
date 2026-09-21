begin;
-- Client compatibility wrappers. They are callable only through Edge Functions
-- after JWT verification; the wallet mutation remains inside Postgres.
create function public.ez_charge_usage(p_user_id uuid,p_feature text,p_model text,p_cost bigint,
  p_idempotency_key uuid,p_request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b bigint; prior public.usage_log%rowtype; log_id uuid; result jsonb;
begin
  if p_user_id is null or p_idempotency_key is null or p_cost<=0 or length(p_request_hash)<>64 then raise exception 'invalid_usage'; end if;
  if not exists(select 1 from public.beta_testers where user_id=p_user_id and enabled) then raise exception 'tester_not_enabled'; end if;
  select balance into b from public.wallets where user_id=p_user_id for update;
  if b is null then raise exception 'wallet_not_found'; end if;
  select * into prior from public.usage_log where user_id=p_user_id and idempotency_key=p_idempotency_key;
  if found then
    if prior.request_hash<>p_request_hash then raise exception 'idempotency_conflict'; end if;
    return prior.response || jsonb_build_object('allowed',true,'balance',b,'idempotent',true,'log_id',prior.id);
  end if;
  if b<p_cost then return jsonb_build_object('allowed',false,'balance',b,'reason','Insufficient coins'); end if;
  b:=b-p_cost; log_id:=gen_random_uuid();
  result:=jsonb_build_object('allowed',true,'balance',b,'log_id',log_id,'charged_credits',p_cost,'pending',true);
  update public.wallets set balance=b,updated_at=now() where user_id=p_user_id;
  insert into public.usage_log(id,user_id,feature,model,charged_credits,idempotency_key,request_hash,response)
    values(log_id,p_user_id,p_feature,p_model,p_cost,p_idempotency_key,p_request_hash,result);
  insert into public.credit_ledger(user_id,delta,balance_after,kind,idempotency_key,feature,metadata)
    values(p_user_id,-p_cost,b,'usage','usage:'||p_idempotency_key,p_feature,jsonb_build_object('log_id',log_id));
  return result;
end $$;

create function public.ez_finish_beta_usage(p_user_id uuid,p_log_id uuid,p_reply text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare row public.usage_log%rowtype; b bigint; result jsonb;
begin
  select * into row from public.usage_log where id=p_log_id and user_id=p_user_id for update;
  if not found then raise exception 'usage_not_found'; end if;
  select balance into b from public.wallets where user_id=p_user_id;
  if row.response ? 'reply' then return row.response || jsonb_build_object('balance',b,'idempotent',true); end if;
  result:=row.response || jsonb_build_object('reply',left(coalesce(p_reply,''),2000),'balance',b,'pending',false);
  update public.usage_log set response=result where id=row.id;
  return result;
end $$;

create function public.ez_complete_usage(p_user_id uuid,p_log_id uuid,p_success boolean,p_metadata jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare row public.usage_log%rowtype;
begin
  select * into row from public.usage_log where id=p_log_id and user_id=p_user_id for update;
  if not found then raise exception 'usage_not_found'; end if;
  update public.usage_log set response=response||jsonb_build_object('completed',p_success,'metadata',coalesce(p_metadata,'{}')) where id=row.id;
  return jsonb_build_object('success',true);
end $$;

create function public.ez_refund_usage(p_user_id uuid,p_log_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare row public.usage_log%rowtype; b bigint; refund_key text;
begin
  select * into row from public.usage_log where id=p_log_id and user_id=p_user_id for update;
  if not found then raise exception 'usage_not_found'; end if;
  refund_key:='refund:'||p_log_id;
  if exists(select 1 from public.credit_ledger where user_id=p_user_id and idempotency_key=refund_key) then
    select balance into b from public.wallets where user_id=p_user_id;
    return jsonb_build_object('success',true,'balance',b,'idempotent',true);
  end if;
  update public.wallets set balance=balance+row.charged_credits,updated_at=now() where user_id=p_user_id returning balance into b;
  insert into public.credit_ledger(user_id,delta,balance_after,kind,idempotency_key,feature,metadata)
    values(p_user_id,row.charged_credits,b,'refund',refund_key,row.feature,jsonb_build_object('reason',left(coalesce(p_reason,''),160)));
  update public.usage_log set response=response||jsonb_build_object('refunded',true) where id=row.id;
  return jsonb_build_object('success',true,'balance',b,'idempotent',false);
end $$;
revoke all on function public.ez_charge_usage(uuid,text,text,bigint,uuid,text),
  public.ez_finish_beta_usage(uuid,uuid,text),public.ez_complete_usage(uuid,uuid,boolean,jsonb),
  public.ez_refund_usage(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.ez_charge_usage(uuid,text,text,bigint,uuid,text),
  public.ez_finish_beta_usage(uuid,uuid,text),public.ez_complete_usage(uuid,uuid,boolean,jsonb),
  public.ez_refund_usage(uuid,uuid,text) to service_role;
commit;
