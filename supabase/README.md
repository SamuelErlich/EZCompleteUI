# Backend beta independente

Este diretório é uma base de implantação para um projeto Supabase novo. Ele não contém URL, chave anon real ou service_role.

## Aplicação

Em uma máquina com a Supabase CLI, a partir da raiz deste repositório:

\`\`\`sh
supabase login
supabase link --project-ref SEU_PROJECT_REF
supabase db push
supabase functions deploy ez-grant-test-credits
supabase functions deploy wallet
supabase functions deploy check-entitlement
supabase functions deploy usage-complete
supabase functions deploy usage-refund
supabase functions deploy ez-chat
supabase functions deploy payments-create
supabase functions deploy payments-webhook
supabase functions deploy get-usage-log
\`\`\`

Defina os secrets apenas no projeto:

\`\`\`sh
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=... \
  --project-ref SEU_PROJECT_REF
\`\`\`

O cliente recebe somente a URL e a chave anon/publishable. Nunca copie a chave service_role para EZSupabaseConfig.m, para o .deb ou para o YouRepo.

No Windows, o script `deploy-beta.ps1` executa esse fluxo depois que
`SUPABASE_ACCESS_TOKEN` for definido apenas na sessão atual do PowerShell. O
Supabase injeta automaticamente as variáveis internas `SUPABASE_*` nas Edge
Functions; não tente cadastrá-las com `supabase secrets set`. Chaves de
provedores externos, quando forem implementadas, serão cadastradas como
secrets próprios e nunca no aplicativo ou no YouRepo.

## Habilitar a concessão de teste

A migration deixa a concessão desligada. Depois de confirmar que o projeto é o beta correto, execute no SQL Editor com uma sessão administrativa:

\`\`\`sql
update public.beta_settings
set allow_test_grants = true
where id = true;

-- Depois que o primeiro usuário criar a conta, libere somente o seu UUID:
insert into public.beta_testers(user_id)
values ('SEU_USER_UUID')
on conflict (user_id) do update set enabled = true;
\`\`\`

O valor vem de test_grant_amount e é ignorado pelo aplicativo. A tabela test_grants e a chave única do ledger impedem uma segunda concessão para o mesmo usuário.

## Pagamentos futuros

payments-create e payments-webhook respondem bloqueados enquanto PAYMENTS_ENABLED não for true. Antes de mudar isso, implemente e teste a verificação de assinatura PayPal/Mercado Pago, retentativas, reconciliação de eventos e a RPC de pagamento. O webhook só deve creditar depois da confirmação no provedor e deve usar o event_id como idempotência.
