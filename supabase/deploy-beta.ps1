$ErrorActionPreference = 'Stop'

# Publishes the independent closed-beta backend. Run this from the repository
# root in PowerShell. Secrets are read from the current process environment and
# are never written to the repository or the iOS app.
$ProjectRef = 'ygssswkgmcofkdowizeo'
$CliArgs = @('--yes', 'supabase@2.117.0')

if (-not $env:SUPABASE_ACCESS_TOKEN) {
    throw 'SUPABASE_ACCESS_TOKEN is missing. Create a Supabase personal access token and set it only in this PowerShell session.'
}
function Invoke-Supabase {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & npx @CliArgs @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Supabase CLI failed with exit code $LASTEXITCODE"
    }
}

Invoke-Supabase @('link', '--project-ref', $ProjectRef)
Invoke-Supabase @('db', 'push', '--project-ref', $ProjectRef)

$Functions = @(
    'ez-grant-test-credits',
    'wallet',
    'check-entitlement',
    'usage-complete',
    'usage-refund',
    'ez-chat',
    'payments-create',
    'payments-webhook',
    'get-usage-log'
)

foreach ($Function in $Functions) {
    Invoke-Supabase @('functions', 'deploy', $Function, '--project-ref', $ProjectRef)
}

Write-Host ''
Write-Host 'Backend beta publicado.' -ForegroundColor Green
Write-Host 'Ainda falta habilitar allow_test_grants e inserir seu UUID em beta_testers no SQL Editor.'
