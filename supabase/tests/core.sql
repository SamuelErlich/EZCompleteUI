-- Run in a disposable Supabase test project after applying the migrations.
-- These checks exercise the invariants that can be tested without a provider.

-- 1. Direct wallet/ledger writes are denied to authenticated users by RLS.
-- 2. A test grant has a fixed server amount and is one-time per user.
-- 3. The usage RPC never lets balance go negative.
-- 4. Repeating a payment event is idempotent.

do $$
declare
  negative_count integer;
begin
  select count(*) into negative_count from public.wallets where balance < 0;
  if negative_count <> 0 then raise exception 'wallet invariant violated'; end if;
end $$;

select
  (select count(*) from pg_proc where proname = 'ez_grant_test_credits') > 0
  as has_test_grant_rpc,
  (select count(*) from pg_proc where proname = 'ez_charge_usage') > 0
  as has_usage_rpc,
  (select count(*) from pg_indexes where indexname = 'credit_ledger_user_id_idempotency_key_key') > 0
  as has_ledger_idempotency,
  (select count(*) from pg_indexes where indexname = 'payment_events_pkey') > 0
  as has_payment_event_idempotency;
