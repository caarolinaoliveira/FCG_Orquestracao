<#
.SYNOPSIS
  Cria o cluster AKS do FCG no Azure, no menor custo possível, e libera o acesso ao Key Vault.

.DESCRIPTION
  ATENÇÃO: este script CRIA RECURSOS PAGOS no Azure. Use -DryRun para apenas ver os comandos
  (nesse modo NENHUM comando "az" é executado, nem de leitura).

  Passos:
    0. Pré-checagens (somente leitura): login, tenant, assinaturas, ACR, Key Vault (RBAC).
    1. Garante os provedores de recurso registrados na assinatura do cluster.
    2. Cria o resource group (se não existir).
    3. az aks create (1 nó Standard_B2ms, plano Free, sem monitoramento, sem upgrades automáticos,
       Key Vault Secrets Provider, Application Routing e acesso ao ACR).
    4. Baixa as credenciais do cluster para o kubeconfig.
    5. Concede "Key Vault Secrets User" à identidade do complemento no Key Vault.
    6. Imprime o Client ID que precisa ir em k8s/overlays/aks/secretproviderclass.yaml.

.PARAMETER DryRun
  Só imprime o que seria executado. Não chama o az.

.EXAMPLE
  .\infra\create-aks.ps1 -DryRun
  .\infra\create-aks.ps1
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$aqui = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $aqui 'config.ps1')

# Executa o az (ou só mostra, no -DryRun). $Leitura marca comandos que não alteram nada.
function Invoke-Az {
    param([string[]]$AzArgs, [switch]$Leitura, [string]$ValorDryRun = '<valor-resolvido-em-tempo-de-execucao>')
    # Só para exibição: coloca aspas nos argumentos com espaço, para o comando impresso poder ser copiado.
    $linha = 'az ' + (($AzArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    if ($DryRun) {
        $tipo = if ($Leitura) { 'leitura' } else { 'CRIA/ALTERA' }
        Write-Host "[DRY-RUN] ($tipo) $linha" -ForegroundColor Yellow
        return $ValorDryRun
    }
    $saida = & az @AzArgs
    if ($LASTEXITCODE -ne 0) { throw "Falha: $linha (exit $LASTEXITCODE)" }
    return $saida
}

if ($DryRun) { Write-Host "MODO DRY-RUN: nenhum comando az sera executado.`n" -ForegroundColor Cyan }

# --- 0. Pré-checagens (somente leitura) -------------------------------------------------------------
Write-Host '== 0. Pre-checagens (somente leitura)'
$tenantAtual = Invoke-Az -Leitura -ValorDryRun $TenantId -AzArgs @('account', 'show', '--query', 'tenantId', '-o', 'tsv')
if (-not $DryRun -and $tenantAtual -ne $TenantId) {
    throw "Voce esta logado no tenant '$tenantAtual', mas o esperado e '$TenantId'. Rode: az login --tenant $TenantId"
}
Invoke-Az -Leitura -AzArgs @('account', 'show', '--subscription', $SubscriptionAks, '--query', 'id', '-o', 'tsv') | Out-Null
Invoke-Az -Leitura -AzArgs @('account', 'show', '--subscription', $SubscriptionAcr, '--query', 'id', '-o', 'tsv') | Out-Null

# ID COMPLETO do ACR (assinatura diferente da do cluster): /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<nome>
$acrId = Invoke-Az -Leitura -ValorDryRun '/subscriptions/<id-da-assinatura-do-acr>/resourceGroups/<rg-do-acr>/providers/Microsoft.ContainerRegistry/registries/fcgcarolina' `
    -AzArgs @('acr', 'show', '--subscription', $SubscriptionAcr, '--name', $AcrName, '--query', 'id', '-o', 'tsv')

# O papel "Key Vault Secrets User" só funciona se o cofre usar RBAC (e não "access policies").
$kvId = Invoke-Az -Leitura -ValorDryRun '/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/kv-fcg-carolina' `
    -AzArgs @('keyvault', 'show', '--subscription', $SubscriptionAcr, '--name', $KeyVaultName, '--query', 'id', '-o', 'tsv')
$kvRbac = Invoke-Az -Leitura -ValorDryRun 'true' `
    -AzArgs @('keyvault', 'show', '--subscription', $SubscriptionAcr, '--name', $KeyVaultName, '--query', 'properties.enableRbacAuthorization', '-o', 'tsv')
if (-not $DryRun -and $kvRbac -ne 'true') {
    throw "O Key Vault '$KeyVaultName' usa access policies, nao RBAC. Habilite 'Permission model: Azure role-based access control' no cofre antes de continuar."
}

# --- 1. Provedores de recurso -----------------------------------------------------------------------
# Assinaturas novas podem nao ter os provedores registrados; o registro e idempotente.
Write-Host '== 1. Provedores de recurso'
foreach ($provedor in 'Microsoft.ContainerService', 'Microsoft.KeyVault') {
    Invoke-Az -AzArgs @('provider', 'register', '--subscription', $SubscriptionAks, '--namespace', $provedor, '--wait') | Out-Null
}

# --- 2. Resource group ------------------------------------------------------------------------------
Write-Host '== 2. Resource group'
Invoke-Az -AzArgs @('group', 'create', '--subscription', $SubscriptionAks, '--name', $ResourceGroup, '--location', $Location) | Out-Null

# --- 3. Cluster AKS ---------------------------------------------------------------------------------
Write-Host '== 3. az aks create (leva alguns minutos)'
$aksCreate = @(
    'aks', 'create',
    '--subscription', $SubscriptionAks,            # assinatura onde o cluster e cobrado (fcg-aks-payg)
    '--resource-group', $ResourceGroup,            # -g: resource group do cluster
    '--name', $ClusterName,                        # nome do cluster
    '--location', $Location,                       # -l: regiao (East US)
    '--node-count', '1',                           # 1 no: menor custo (sem alta disponibilidade)
    '--node-vm-size', 'Standard_B2ms',             # VM burstable de 2 vCPUs e 8 GB: o item mais caro; desligue com stop-aks.ps1 quando nao usar
    '--node-osdisk-size', '32',                    # disco do SO em GB (padrao e 128): menor disco, menor custo
    '--tier', 'free',                              # plano Free: control plane sem custo (sem SLA)
    '--auto-upgrade-channel', 'none',              # nao atualiza a versao do Kubernetes sozinho (evita reinicios surpresa)
    '--node-os-upgrade-channel', 'None',           # nao atualiza a imagem do SO dos nos sozinho
    '--enable-addons', 'azure-keyvault-secrets-provider',  # Secrets Store CSI Driver: le segredos do Key Vault
    '--enable-app-routing',                        # Application Routing: NGINX gerenciado (IngressClass webapprouting.kubernetes.azure.com)
    '--attach-acr', $acrId,                        # da permissao AcrPull ao cluster no ACR (ID COMPLETO: ACR em outra assinatura)
    '--no-ssh-key'                                 # nao gera chaves SSH na sua maquina (os nos nao sao acessados por SSH)
    # Monitoramento: o complemento "monitoring" NAO e habilitado (nao ha --enable-addons monitoring),
    # entao nao ha Log Analytics nem custo de ingestao. A observabilidade e feita pelo New Relic.
)
Invoke-Az -AzArgs $aksCreate | Out-Null

# --- 4. Credenciais ---------------------------------------------------------------------------------
Write-Host '== 4. Credenciais do kubectl'
Invoke-Az -AzArgs @('aks', 'get-credentials', '--subscription', $SubscriptionAks, '--resource-group', $ResourceGroup,
    '--name', $ClusterName, '--overwrite-existing') | Out-Null

# --- 5. Papel no Key Vault para a identidade do complemento ----------------------------------------
Write-Host '== 5. Key Vault Secrets User para a identidade do complemento'
# Duas consultas simples, sem virgula na expressao: no Windows o "az" e um az.cmd (batch) e o cmd.exe
# trata virgula sem aspas como separador de argumentos.
$clientId = Invoke-Az -Leitura -ValorDryRun '<client-id>' `
    -AzArgs @('aks', 'show', '--subscription', $SubscriptionAks, '--resource-group', $ResourceGroup, '--name', $ClusterName,
        '--query', 'addonProfiles.azureKeyvaultSecretsProvider.identity.clientId', '-o', 'tsv')
$objectId = Invoke-Az -Leitura -ValorDryRun '<object-id>' `
    -AzArgs @('aks', 'show', '--subscription', $SubscriptionAks, '--resource-group', $ResourceGroup, '--name', $ClusterName,
        '--query', 'addonProfiles.azureKeyvaultSecretsProvider.identity.objectId', '-o', 'tsv')

Invoke-Az -AzArgs @('role', 'assignment', 'create',
    '--assignee-object-id', $objectId,               # objectId da identidade gerenciada do complemento
    '--assignee-principal-type', 'ServicePrincipal', # evita esperar a replicacao do AAD
    '--role', 'Key Vault Secrets User',              # somente leitura de segredos (minimo privilegio)
    '--scope', $kvId) | Out-Null                     # restrito a este Key Vault

# --- 6. Proximo passo manual ------------------------------------------------------------------------
Write-Host ''
Write-Host '== Concluido. PROXIMO PASSO MANUAL:' -ForegroundColor Green
Write-Host "Edite k8s/overlays/aks/secretproviderclass.yaml e troque o valor de 'userAssignedIdentityID' por:"
Write-Host "    $clientId" -ForegroundColor Green
Write-Host 'Depois: kubectl apply -k k8s/overlays/aks   (veja o README).'
