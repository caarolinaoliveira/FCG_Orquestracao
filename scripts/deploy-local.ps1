<#
.SYNOPSIS
  Constrói as imagens com uma TAG ÚNICA e aplica o overlay local no Kubernetes do Docker Desktop.

.DESCRIPTION
  Por que tag única: o nó do Docker Desktop (kind) guarda em cache as imagens por tag e, com a política
  de pull padrão (IfNotPresent), reaproveita a imagem ANTIGA mesmo depois de você reconstruir a mesma
  tag (por exemplo "local") e reiniciar o Deployment. Cada build com uma tag nova elimina o problema, e é
  exatamente o que a pipeline fará no AKS (uma tag por build, como o SHA do commit). Não usamos
  "imagePullPolicy: Always": a imagem local não está em nenhum registry e o pod cairia em ErrImagePull.

  Passos:
    1. Gera a tag (padrão: local-<aaaammddhhmmss>).
    2. docker compose build, com IMAGE_TAG=<tag>   (gera fcg/<app>:<tag>).
    3. Recria os Secrets locais (scripts/create-local-secrets.ps1, a partir do .env).
    4. Gera um overlay TEMPORÁRIO (k8s/overlays/local-run, ignorado pelo git) que só define o bloco
       "images:" com a tag nova - o equivalente de "kustomize edit set image" da pipeline, sem alterar
       nenhum arquivo versionado - e aplica com kubectl apply -k.
    5. Aguarda o rollout e mostra a tag e o digest de cada pod.

.PARAMETER Tag
  Tag das imagens. Padrão: local-<aaaammddhhmmss>.

.PARAMETER Context
  Contexto do kubectl permitido (padrão: docker-desktop).

.PARAMETER SemBuild
  Pula o docker compose build (usa imagens já construídas com a -Tag informada).

.PARAMETER LimparImagensAntigas
  Remove do nó as imagens fcg/* de tags anteriores (o cache do nó cresce a cada build).

.EXAMPLE
  .\scripts\deploy-local.ps1
  .\scripts\deploy-local.ps1 -Tag local-meu-teste -LimparImagensAntigas
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Context = 'docker-desktop',
    [switch]$SemBuild,
    [switch]$LimparImagensAntigas
)

$ErrorActionPreference = 'Stop'
$raiz = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
Set-Location $raiz

if (-not $Tag) { $Tag = 'local-' + (Get-Date -Format 'yyyyMMddHHmmss') }
if ($Tag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') { throw "Tag invalida: '$Tag'." }
if ($Tag -eq 'latest') { throw "Nao use 'latest': o nó reaproveitaria a imagem em cache." }

# Trava de seguranca: so age no contexto permitido.
$contextos = & kubectl config get-contexts -o name
if ($contextos -notcontains $Context) { throw "Contexto '$Context' nao encontrado no kubectl." }
if (-not (Test-Path (Join-Path $raiz '.env'))) { throw "Arquivo .env nao encontrado em '$raiz'. Copie o .env.example e preencha." }

$apps = @('usuarios-api', 'catalogo-api', 'pagamentos-worker', 'notificacoes-worker')
Write-Host "Contexto: $Context | Tag: $Tag"

# --- 1. Build com a tag unica ---------------------------------------------------------------------
if (-not $SemBuild) {
    Write-Host "== docker compose build (IMAGE_TAG=$Tag)"
    $env:IMAGE_TAG = $Tag
    try { & docker compose build; if ($LASTEXITCODE -ne 0) { throw "docker compose build falhou (exit $LASTEXITCODE)." } }
    finally { Remove-Item Env:\IMAGE_TAG -ErrorAction SilentlyContinue }
}

# --- 2. Secrets -------------------------------------------------------------------------------------
Write-Host '== Secrets locais'
& (Join-Path $PSScriptRoot 'create-local-secrets.ps1') -Context $Context | Out-Null

# --- 3. Overlay temporario com a tag ---------------------------------------------------------------
$tmp = Join-Path $raiz 'k8s\overlays\local-run'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$imagens = ($apps | ForEach-Object { "  - name: fcg/$_`n    newTag: $Tag" }) -join "`n"
@"
# GERADO por scripts/deploy-local.ps1 - nao versionar, nao editar.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../local
images:
$imagens
"@ | Set-Content -Path (Join-Path $tmp 'kustomization.yaml') -Encoding utf8

try {
    Write-Host '== kubectl apply -k (overlay local com a tag nova)'
    & kubectl --context $Context apply -k $tmp
    if ($LASTEXITCODE -ne 0) { throw 'kubectl apply falhou.' }

    # --- 4. Rollout ---------------------------------------------------------------------------------
    foreach ($app in $apps) {
        & kubectl --context $Context -n fcg rollout status "deploy/$app" --timeout=300s
        if ($LASTEXITCODE -ne 0) { throw "Rollout de $app nao concluiu." }
    }
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

# --- 5. Limpeza opcional do cache do no ------------------------------------------------------------
if ($LimparImagensAntigas) {
    $no = (& docker ps --filter 'name=desktop-control-plane' --format '{{.Names}}' | Select-Object -First 1)
    if ($no) {
        # ATENCAO: "crictl rmi <tag>" apaga a IMAGEM inteira (todas as tags dela). Se uma app nao mudou, a tag
        # antiga e a nova apontam para a MESMA imagem e o rmi apagaria tambem a tag atual. Por isso removemos
        # so o NOME da tag antiga com "ctr images rm", que apaga a referencia e preserva a imagem.
        # No PS 5.1, com 'Stop', o stderr do docker/ctr vira erro fatal; a limpeza não pode derrubar o deploy.
        $erroAnterior = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $itens = & docker exec $no crictl images 2>$null | Select-String 'docker.io/fcg/'
            foreach ($i in $itens) {
                $c = ($i.ToString() -split '\s+')
                # Imagem sem tag (<none>) não tem nome para remover.
                if ($c[1] -eq $Tag -or $c[1] -eq '<none>') { continue }
                & docker exec $no ctr -n k8s.io images rm "$($c[0]):$($c[1])" 2>&1 | Out-Null
                Write-Host "  tag removida do no: $($c[0]):$($c[1])"
            }
        }
        finally { $ErrorActionPreference = $erroAnterior }
    }
}

# --- 6. Resumo --------------------------------------------------------------------------------------
Write-Host "`n== Imagens em uso (tag e digest)"
foreach ($app in $apps) {
    $json = & kubectl --context $Context -n fcg get pods -l "app.kubernetes.io/name=$app" -o json | ConvertFrom-Json
    foreach ($p in $json.items | Where-Object { -not $_.metadata.deletionTimestamp }) {
        $cs = $p.status.containerStatuses[0]
        '{0,-22} {1}  {2}' -f $app, $p.spec.containers[0].image, ($cs.imageID -replace '^.*@', '')
    }
}
Write-Host "`nPronto. Tag desta implantacao: $Tag"
