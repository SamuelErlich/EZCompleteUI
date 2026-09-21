-- Future sandbox payment boundary. NO live payment adapters are deployed.
begin;
create table public.payment_settings (
  id boolean primary key default true check(id),
  sandbox_enabled boolean not null default false
);
insert into public.payment_settings(id) values(true);
create table public.payment_packages (
  package_id text primary key,
  credits bigint not null check(credits between 1 and 1000000),
  amount_cents integer not null check(amount_cents>0),
  currency text not null check(currency ~ '^[A-Z]{3}$'),
  enabled boolean not null default false
);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  provider text not null check(provider in ('paypal','mercadopago')),
  environment text not null default 'sandbox' check(environment='sandbox'),
  package_id text not null references public.payment_packages(package_id),
  amount_cents integer not null check(amount_cents>0),
  currency text not null,
  credits bigint not null check(credits>0),
  status text not null default 'pending' check(status in ('pending','approved','cancelled','refunded')),
  idempotency_key uuid not null,
  provider_payment_id text,
  created_at timestamptz not null default now(), approved_at timestamptz,
  unique(user_id,provider,environment,idempotency_key),
  unique(provider,environment,provider_payment_id)
);
create table public.payment_events (
  provider text not null,
  environment text not null check(environment='sandbox'),
  event_id text not null,
  payment_id uuid not null references public.payments(id),
  provider_payment_id text not null,
  received_at timestamptz not null default now(),
  primary key(provider,environment,event_id)
);
create function public.ez_prepare_payment(p_user_id uuid,p_provider text,p_package_id text,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare pkg public.payment_packages%rowtype; pay public.payments%rowtype;
begin
  if not exists(select 1 from public.payment_settings where id and sandbox_enabled) then
    raise exception 'payments_disabled';
  end if;
  if p_key is null or p_provider not in ('paypal','mercadopago') then raise exception 'invalid_payment'; end if;
  select * into pkg from public.payment_packages where package_id=p_package_id and enabled;
  if not found then raise exception 'package_disabled'; end if;
  -- A unique constraint makes simultaneous create retries return the same row.
  insert into public.payments(user_id,provider,package_id,amount_cents,currency,credits,idempotency_key)
    values(p_user_id,p_provider,p_package_id,pkg.amount_cents,pkg.currency,pkg.credits,p_key)
    on conflict(user_id,provider,environment,idempotency_key) do nothing;
  select * into pay from public.payments where user_id=p_user_id and provider=p_provider
    and environment='sandbox' and idempotency_key=p_key;
  if pay.package_id<>p_package_id then raise exception 'idempotency_conflict'; end if;
  return to_jsonb(pay);
end $$;

-- Called ONLY after a future adapter verifies the provider's signature AND
-- fetches the approved transaction, amount, currency, merchant and reference.
-- Incoming client amounts or credits never reach this function.
create function public.ez_record_approved_payment(p_payment_id uuid,p_provider text,p_event_id text,
  p_provider_payment_id text,p_amount_cents integer,p_currency text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare pay public.payments%rowtype; prior public.payment_events%rowtype; b bigint;
begin
  if not exists(select 1 from public.payment_settings where id and sandbox_enabled) then
    raise exception 'payments_disabled';
  end if;
  if p_event_id is null or length(p_event_id) not between 1 and 200
     or p_provider_payment_id is null or length(p_provider_payment_id) not between 1 and 200 then
    raise exception 'invalid_payment_reference';
  end if;
  select * into pay from public.payments where id=p_payment_id for update;
  if not found then raise exception 'payment_not_found'; end if;
  if p_provider is distinct from pay.provider or p_amount_cents is distinct from pay.amount_cents
    or p_currency is distinct from pay.currency then raise exception 'payment_mismatch'; end if;
  if pay.status not in ('pending','approved') then raise exception 'invalid_payment_state'; end if;
  if pay.provider_payment_id is not null and pay.provider_payment_id<>p_provider_payment_id then
    raise exception 'provider_payment_conflict';
  end if;
  insert into public.payment_events(provider,environment,event_id,payment_id,provider_payment_id)
    values(p_provider,'sandbox',p_event_id,p_payment_id,p_provider_payment_id) on conflict do nothing;
  select * into prior from public.payment_events where provider=p_provider
    and environment='sandbox' and event_id=p_event_id;
  if prior.payment_id<>p_payment_id or prior.provider_payment_id<>p_provider_payment_id then
    raise exception 'event_conflict';
  end if;
  select balance into b from public.wallets where user_id=pay.user_id for update;
  if b is null then raise exception 'wallet_not_found'; end if;
  -- A different event for the SAME transaction must also credit exactly once.
  if pay.status='approved' then
    return jsonb_build_object('success',true,'idempotent',true,'balance',b,'credits_added',0);
  end if;
  update public.payments set status='approved',provider_payment_id=p_provider_payment_id,
    approved_at=now() where id=pay.id;
  b := b+pay.credits;
  update public.wallets set balance=b,updated_at=now() where user_id=pay.user_id;
  insert into public.credit_ledger(user_id,delta,balance_after,kind,idempotency_key,feature,metadata)
    values(pay.user_id,pay.credits,b,'payment','payment:'||pay.id,'sandbox_payment',
      jsonb_build_object('payment_id',pay.id,'environment','sandbox'));
  return jsonb_build_object('success',true,'idempotent',false,'balance',b,'credits_added',pay.credits);
end $$;

alter table public.payment_settings enable row level security;
alter table public.payment_packages enable row level security;
alter table public.payments enable row level security;
alter table public.payment_events enable row level security;
revoke all on public.payment_settings,public.payment_packages,public.payments,public.payment_events
  from public,anon,authenticated;
grant all on public.payment_settings,public.payment_packages,public.payments,public.payment_events to service_role;
grant select on public.payments to authenticated;
create policy payments_self on public.payments for select to authenticated using(user_id=auth.uid());
revoke all on function public.ez_prepare_payment(uuid,text,text,uuid),
  public.ez_record_approved_payment(uuid,text,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.ez_prepare_payment(uuid,text,text,uuid),
  public.ez_record_approved_payment(uuid,text,text,text,integer,text) to service_role;
commit;
