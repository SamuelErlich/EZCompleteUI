# EZComplete Beta — caminho seguro

Esta árvore é uma reconstrução independente para testes no YouRepo, com tema escuro azul/roxo e localização PT-BR. O bundle beta é \`com.gabriel.ezcomplete.beta\`, separado de \`com.i0stweak3r.ezcompleteui\`.

## O que foi reconstruído

- \`EZAuthManager.m\`: cadastro, login, recuperação de senha, refresh single-flight, expiração e sessão no Keychain.
- \`EZKeyVault.m\`: armazenamento device-only no Keychain, sem segredo de servidor nem criptografia inventada no cliente.
- \`EZEntitlementManager.m\`: saldo somente leitura, débito/refund e ledger via funções Supabase.
- \`supabase/migrations/\`: perfis, carteira, ledger append-only, uso, assinaturas, pagamentos, eventos e idempotência.
- \`supabase/functions/\`: wallet, crédito de teste único, cobrança de uso, chat beta determinístico e endpoints de pagamentos desativados.

O app não usa a URL ou a chave do autor. \`EZSupabaseConfig.m\` permanece com \`YOUR_PROJECT_REF\` e chave vazia até um novo projeto Supabase ser criado. Com esse placeholder, o app falha fechado e não tenta autenticar.

## Créditos na beta

O botão de créditos chama \`ez-grant-test-credits\`. O valor é definido no servidor, não é enviado pelo cliente, e cada usuário só pode receber uma concessão. A migration cria \`allow_test_grants = false\`; depois de criar o projeto de testes, habilite-o somente no painel/SQL com a chave \`service_role\`. Pagamentos PayPal, Pix, cartão e Mercado Pago continuam bloqueados.

O chat beta devolve uma resposta determinística quando \`OPENAI_API_KEY\` não está configurada. Isso permite testar login, ledger, débito, retry e saldo sem consumir uma API paga. A ligação com OpenAI, imagens, PayPal e Mercado Pago deve ser ativada depois, em funções separadas e com segredos exclusivamente no servidor.

## Verificação local

\`\`\`sh
python3 scripts/validate_redesign.py --strict
\`\`\`

Não é possível gerar o \`.deb\` neste ambiente: faltam Theos, Xcode, clang e um SDK iPhoneOS. Em um Mac com Theos:

\`\`\`sh
export THEOS="$HOME/theos"
./build.sh
\`\`\`

O script exige rootless, verifica o bundle beta, executa o preflight, localiza o app em \`/var/jb/Applications/EZCompleteUI.app\`, cria o IPA a partir do estágio assinado e valida o \`.deb\`. Só depois do teste no aparelho o pacote deve ser enviado ao YouRepo.

## Configuração necessária para a próxima etapa

1. Criar um projeto Supabase novo e aplicar as três migrations.
2. Habilitar \`allow_test_grants\` no ambiente beta.
3. Copiar a URL e a chave anon/publishable para \`EZSupabaseConfig.m\` em uma configuração local.
4. Compilar com Theos e testar cadastro, login, concessão única, chat beta, consumo, refund e logout.
5. Somente depois decidir o adaptador de provedor: PayPal, Mercado Pago (Pix/cartão) ou StoreKit 2 para App Store.

Nunca coloque \`service_role\`, token PayPal ou segredo Mercado Pago no app ou no \`.deb\`.
