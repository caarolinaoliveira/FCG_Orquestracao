<#
.SYNOPSIS
  Desliga o cluster AKS (para a VM do nó e o control plane) para parar o custo de computação.

.DESCRIPTION
  Quando parado: a VM do nó deixa de ser cobrada. Continuam existindo (e podendo gerar custo): os discos
  gerenciados (PVCs e disco do SO) e o Load Balancer/IP público do Ingress. Os dados nos PVCs são mantidos.
  O Elasticsearch usa emptyDir: o índice é perdido ao desligar (será refeito pela reindexação).
  Para ligar de novo: start-aks.ps1.

.PARAMETER DryRun
  Só imprime o que seria executado. Não chama o az.
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$aqui = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $aqui 'config.ps1')

$comando = @('aks', 'stop',
    '--subscription', $SubscriptionAks,   # assinatura do cluster
    '--resource-group', $ResourceGroup,   # -g
    '--name', $ClusterName)               # nome do cluster

if ($DryRun) {
    Write-Host ('[DRY-RUN] az ' + (($comando | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')) -ForegroundColor Yellow
    return
}

Write-Host "Desligando o cluster '$ClusterName'..."
& az @comando
if ($LASTEXITCODE -ne 0) { throw "Falha ao desligar o cluster (exit $LASTEXITCODE)." }
Write-Host 'Cluster desligado.'
