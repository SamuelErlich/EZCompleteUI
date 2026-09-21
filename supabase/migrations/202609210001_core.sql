-- NEW, EMPTY Supabase project only. All mutations are transactional.
begin;
create table public.profiles (
  id uuid primary key references auth.users(id),
  display_name text,
  created_at timestamptz not null default now()
);
create table public.wallets (
  user_id uuid primary key references public.profiles(id),
  balance bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);
create table public.subscriptions (
  user_id uuid primary key references public.profiles(id),
  tier text not null default 'free',
  status text not null default 'coins_only' check (status in ('active','cancelled','suspended','expired','coins_only')),
  provider text, provider_subscription_id text,
  current_period_end timestamptz, updated_at timestamptz not null default now()
);
create table public.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  delta bigint not null check (delta <> 0),
  balance_after bigint not null check (balance_after >= 0),
  kind text not null check (kind in ('test_grant','usage','refund','payment')),
  idempotency_key text not null,
  feature text, metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  unique (user_id,idempotency_key)
);
create index ledger_user_date on public.credit_ledger(user_id,created_at desc,id);
create table public.usage_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  feature text not null, model text not null,
  charged_credits bigint not null check (charged_credits > 0),
  idempotency_key uuid not null, request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  unique (user_id,idempotency_key)
);
create table public.beta_settings (
  id boolean primary key default true check (id),
  allow_test_grants boolean not null default false,
  test_grant_amount bigint not null default 100 check (test_grant_amount between 1 and 10000)
);
create table public.beta_testers (
  user_id uuid primary key references public.profiles(id),
  enabled boolean not null default true
);
create table public.test_grants (
  user_id uuid primary key references public.profiles(id),
  grant_key uuid not null, amount bigint not null check (amount>0),
  created_at timestamptz not null default now()
);
insert into public.beta_settings(id) values(true);

create function public.ez_touch_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.profiles(id) values(new.id);
  insert into public.wallets(user_id) values(new.id);
  insert into public.subscriptions(user_id) values(new.id);
  return new;
end $$;
create trigger on_auth_user_created_ezcomplete after insert on auth.users
  for each row execute function public.ez_touch_new_user();
-- Also supports accounts created before the migrations were applied.
insert into public.profiles(id) select id from auth.users on conflict do nothing;
insert into public.wallets(user_id) select id from public.profiles on conflict do nothing;
insert into public.subscriptions(user_id) select id from public.profiles on conflict do nothing;

-- Any correction must be another ledger entry, never an edit of history.
create function public.ez_ledger_immutable() returns trigger
language plpgsql set search_path='' as $$
begin raise exception 'ledger_is_append_only'; end $$;
create trigger ledger_immutable before update or delete on public.credit_ledger
  for each row execute function public.ez_ledger_immutable();

create function public.ez_grant_test_credits(p_grant_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  uid uuid := auth.uid(); amount bigint; b bigint;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if p_grant_key is null then raise exception 'invalid_grant_key'; end if;
  if not exists(select 1 from public.beta_testers where user_id=uid and enabled) then
    raise exception 'tester_not_enabled';
  end if;
  select test_grant_amount into amount from public.beta_settings where id and allow_test_grants;
  if amount is null then raise exception 'test_grants_disabled'; end if;
  -- Serialize all operations for this wallet BEFORE checking idempotency.
  select balance into b from public.wallets where user_id=uid for update;
  if b is null then raise exception 'wallet_not_found'; end if;
  if exists(select 1 from public.test_grants where user_id=uid) then
    return jsonb_build_object('success',true,'credits_added',0,'balance',b,'one_time',true);
  end if;
  insert into public.test_grants(user_id,grant_key,amount) values(uid,p_grant_key,amount);
  b := b+amount;
  update public.wallets set balance=b,updated_at=now() where user_id=uid;
  insert into public.credit_ledger(user_id,delta,balance_after,kind,idempotency_key,feature)
    values(uid,amount,b,'test_grant','initial-beta-grant','test_grant');
  return jsonb_build_object('success',true,'credits_added',amount,'balance',b,'one_time',true);
end $$;

create function public.ez_wallet_snapshot() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select jsonb_build_object('balance',w.balance,'tier',s.tier,'status',s.status,
    'has_ever_purchased',false,'beta',true,
    'tester_enabled',exists(select 1 from public.beta_testers where user_id=w.user_id and enabled))
    into result from public.wallets w join public.subscriptions s on s.user_id=w.user_id
    where w.user_id=auth.uid();
  if result is null then raise exception 'wallet_not_found'; end if;
  return result;
end $$;
create function public.ez_test_grant_status() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  return jsonb_build_object(
    'available',coalesce((select allow_test_grants from public.beta_settings where id),false)
      and exists(select 1 from public.beta_testers where user_id=auth.uid() and enabled)
      and not exists(select 1 from public.test_grants where user_id=auth.uid()),
    'claimed',exists(select 1 from public.test_grants where user_id=auth.uid()),
    'coins_to_award',coalesce((select test_grant_amount from public.beta_settings where id and allow_test_grants),0),
    'one_time',true);
end $$;

-- Demo ONLY: no external provider call. Debit and stored response are committed
-- together. Price is fixed here, never supplied by the client/Edge Function.
-- EXECUTE is granted solely to service_role after JWT verification at the Edge.
create function public.ez_run_beta_chat(p_user_id uuid,p_key uuid,p_hash text,p_reply text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b bigint; previous public.usage_log%rowtype; result jsonb; log_id uuid;
begin
  if p_key is null or p_hash is null or length(p_hash)<>64 or p_reply is null or length(p_reply)>2000 then
    raise exception 'invalid_request';
  end if;
  if not exists(select 1 from public.beta_testers where user_id=p_user_id and enabled) then
    raise exception 'tester_not_enabled';
  end if;
  select balance into b from public.wallets where user_id=p_user_id for update;
  if b is null then raise exception 'wallet_not_found'; end if;
  select * into previous from public.usage_log where user_id=p_user_id and idempotency_key=p_key;
  if found then
    if previous.request_hash<>p_hash then raise exception 'idempotency_conflict'; end if;
    return previous.response || jsonb_build_object('balance',b,'idempotent',true);
  end if;
  if b<1 then return jsonb_build_object('error','Insufficient coins','balance',b); end if;
  b := b-1; log_id := gen_random_uuid();
  result := jsonb_build_object('reply',p_reply,'balance',b,'beta',true,'log_id',log_id,
    'charged_credits',1,'model','beta-demo','idempotent',false);
  update public.wallets set balance=b,updated_at=now() where user_id=p_user_id;
  insert into public.usage_log(id,user_id,feature,model,charged_credits,idempotency_key,request_hash,response)
    values(log_id,p_user_id,'chat_beta','beta-demo',1,p_key,p_hash,result);
  insert into public.credit_ledger(user_id,delta,balance_after,kind,idempotency_key,feature,metadata)
    values(p_user_id,-1,b,'usage','chat:'||p_key,'chat_beta',jsonb_build_object('log_id',log_id,'model','beta-demo'));
  return result;
end $$;

-- Explicit table privileges plus RLS: clients can only read their own data.
alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.subscriptions enable row level security;
alter table public.credit_ledger enable row level security;
alter table public.usage_log enable row level security;
alter table public.beta_settings enable row level security;
alter table public.beta_testers enable row level security;
alter table public.test_grants enable row level security;
revoke all on public.profiles,public.wallets,public.subscriptions,public.credit_ledger,
  public.usage_log,public.beta_settings,public.beta_testers,public.test_grants from public,anon,authenticated;
grant select on public.profiles,public.wallets,public.subscriptions,public.credit_ledger,public.usage_log to authenticated;
grant all on public.profiles,public.wallets,public.subscriptions,public.credit_ledger,
  public.usage_log,public.beta_settings,public.beta_testers,public.test_grants to service_role;
create policy profiles_self on public.profiles for select to authenticated using(id=auth.uid());
create policy wallet_self on public.wallets for select to authenticated using(user_id=auth.uid());
create policy subscription_self on public.subscriptions for select to authenticated using(user_id=auth.uid());
create policy ledger_self on public.credit_ledger for select to authenticated using(user_id=auth.uid());
create policy usage_self on public.usage_log for select to authenticated using(user_id=auth.uid());

-- Functions are PUBLIC-executable by default; revoke PUBLIC explicitly.
revoke all on function public.ez_touch_new_user(),public.ez_ledger_immutable(),
  public.ez_grant_test_credits(uuid),public.ez_wallet_snapshot(),public.ez_test_grant_status(),
  public.ez_run_beta_chat(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.ez_grant_test_credits(uuid),public.ez_wallet_snapshot(),
  public.ez_test_grant_status() to authenticated;
grant execute on function public.ez_run_beta_chat(uuid,uuid,text,text) to service_role;
commit;
