<#
.SYNOPSIS
  Cria os 5 Secrets do FCG no Kubernetes LOCAL (Docker Desktop) a partir do arquivo .env.

.DESCRIPTION
  Lê o .env e roda "kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -".
  - Nunca grava arquivo com valores de segredo (os valores só passam pelo kubectl).
  - É idempotente: pode rodar de novo para atualizar.
  - Só age no contexto indicado (padrão: docker-desktop), para não criar segredos locais num cluster
    errado por engano (por exemplo, o AKS).

  Secrets criados (mesmos nomes e chaves esperados pelos Deployments):
    infra-secrets        MSSQL_SA_PASSWORD, RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASS
    usuarios-secrets     ConnectionStrings__DefaultConnection, RabbitMQ__Usuario, RabbitMQ__Senha, JwtSettings__Segredo, NEW_RELIC_LICENSE_KEY
    catalogo-secrets     (mesmas chaves, connection string do banco FCG_Catalogo)
    pagamentos-secrets   ConnectionStrings__DefaultConnection, RabbitMQ__Usuario, RabbitMQ__Senha, NEW_RELIC_LICENSE_KEY
    notificacoes-secrets RabbitMQ__Usuario, RabbitMQ__Senha, NEW_RELIC_LICENSE_KEY

.PARAMETER EnvFile
  Caminho do .env (padrão: ..\.env em relação a este script, ou seja, a raiz do FCG_Orquestracao).

.PARAMETER Context
  Contexto do kubectl permitido (padrão: docker-desktop).

.PARAMETER Namespace
  Namespace de destino (padrão: fcg).

.EXAMPLE
  .\scripts\create-local-secrets.ps1
#>
[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$Context = 'docker-desktop',
    [string]$Namespace = 'fcg'
)

$ErrorActionPreference = 'Stop'

# Calculado aqui (e não no valor padrão do parâmetro): no Windows PowerShell 5.1 o $PSScriptRoot
# vem vazio dentro do bloco param().
if (-not $EnvFile) {
    $raizScript = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $EnvFile = Join-Path $raizScript '..\.env'
}

function Invoke-Kubectl {
    & kubectl --context $Context @args
    if ($LASTEXITCODE -ne 0) { throw "kubectl falhou (exit $LASTEXITCODE): kubectl $($args[0..1] -join ' ')" }
}

# --- Trava de segurança: o contexto ativo precisa existir e ser o permitido ---------------------
$contextos = & kubectl config get-contexts -o name
if ($contextos -notcontains $Context) { throw "Contexto '$Context' não encontrado no kubectl." }
Write-Host "Contexto: $Context | Namespace: $Namespace"

# --- Leitura do .env (ignora comentários e linhas vazias) ---------------------------------------
if (-not (Test-Path $EnvFile)) { throw "Arquivo .env não encontrado em '$EnvFile'. Copie o .env.example e preencha." }
$vars = @{}
foreach ($linha in Get-Content $EnvFile) {
    if ($linha -match '^\s*#' -or $linha -match '^\s*$') { continue }
    $i = $linha.IndexOf('=')
    if ($i -lt 1) { continue }
    $vars[$linha.Substring(0, $i).Trim()] = $linha.Substring($i + 1).Trim()
}

foreach ($obrigatoria in 'SA_PASSWORD', 'RABBITMQ_USER', 'RABBITMQ_PASSWORD', 'JWT_SECRET') {
    if (-not $vars[$obrigatoria]) { throw "Variável obrigatória '$obrigatoria' ausente no .env." }
}
if ($vars['JWT_SECRET'].Length -lt 32) { throw "JWT_SECRET precisa ter no mínimo 32 caracteres." }
$newRelicKey = if ($vars['NEW_RELIC_LICENSE_KEY']) { $vars['NEW_RELIC_LICENSE_KEY'] } else { '' }

$sa = $vars['SA_PASSWORD']
function Get-Conn([string]$banco) {
    "Server=fcg-sqlserver,1433;Database=$banco;User Id=sa;Password=$sa;TrustServerCertificate=True;"
}

# --- Namespace (idempotente) --------------------------------------------------------------------
Invoke-Kubectl create namespace $Namespace --dry-run=client -o yaml | & kubectl --context $Context apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Falha ao criar o namespace '$Namespace'." }

function New-Secret([string]$nome, [string[]]$literais) {
    $argumentos = @('create', 'secret', 'generic', $nome, '-n', $Namespace) + $literais + @('--dry-run=client', '-o', 'yaml')
    & kubectl --context $Context @argumentos | & kubectl --context $Context apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar o secret '$nome'." }
    Write-Host "  ok  $nome"
}

$rabbit = @("--from-literal=RabbitMQ__Usuario=$($vars['RABBITMQ_USER'])", "--from-literal=RabbitMQ__Senha=$($vars['RABBITMQ_PASSWORD'])")
$nr = "--from-literal=NEW_RELIC_LICENSE_KEY=$newRelicKey"

New-Secret 'infra-secrets' @(
    "--from-literal=MSSQL_SA_PASSWORD=$sa",
    "--from-literal=RABBITMQ_DEFAULT_USER=$($vars['RABBITMQ_USER'])",
    "--from-literal=RABBITMQ_DEFAULT_PASS=$($vars['RABBITMQ_PASSWORD'])")

New-Secret 'usuarios-secrets' (@("--from-literal=ConnectionStrings__DefaultConnection=$(Get-Conn 'FCG_Usuarios')") + $rabbit + @("--from-literal=JwtSettings__Segredo=$($vars['JWT_SECRET'])", $nr))
New-Secret 'catalogo-secrets' (@("--from-literal=ConnectionStrings__DefaultConnection=$(Get-Conn 'FCG_Catalogo')") + $rabbit + @("--from-literal=JwtSettings__Segredo=$($vars['JWT_SECRET'])", $nr))
New-Secret 'pagamentos-secrets' (@("--from-literal=ConnectionStrings__DefaultConnection=$(Get-Conn 'FCG_Pagamentos')") + $rabbit + @($nr))
New-Secret 'notificacoes-secrets' ($rabbit + @($nr))

Write-Host "Pronto. Agora: kubectl --context $Context apply -k k8s/overlays/local"
