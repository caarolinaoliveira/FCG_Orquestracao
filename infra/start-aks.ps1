<#
.SYNOPSIS
  Liga o cluster AKS que foi parado com stop-aks.ps1 e atualiza o kubeconfig.

.DESCRIPTION
  Depois de ligar, os pods voltam sozinhos (os Deployments e os PVCs continuam no cluster).
  O primeiro start pode levar alguns minutos.

.PARAMETER DryRun
  Só imprime o que seria executado. Não chama o az.
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$aqui = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $aqui 'config.ps1')

$start = @('aks', 'start',
    '--subscription', $SubscriptionAks,   # assinatura do cluster
    '--resource-group', $ResourceGroup,   # -g
    '--name', $ClusterName)               # nome do cluster

$credenciais = @('aks', 'get-credentials',
    '--subscription', $SubscriptionAks,
    '--resource-group', $ResourceGroup,
    '--name', $ClusterName,
    '--overwrite-existing')               # atualiza o contexto existente no kubeconfig

if ($DryRun) {
    Write-Host ('[DRY-RUN] az ' + ($start -join ' ')) -ForegroundColor Yellow
    Write-Host ('[DRY-RUN] az ' + ($credenciais -join ' ')) -ForegroundColor Yellow
    return
}

Write-Host "Ligando o cluster '$ClusterName'..."
& az @start
if ($LASTEXITCODE -ne 0) { throw "Falha ao ligar o cluster (exit $LASTEXITCODE)." }

& az @credenciais
if ($LASTEXITCODE -ne 0) { throw "Falha ao obter as credenciais (exit $LASTEXITCODE)." }

Write-Host 'Cluster ligado. Acompanhe os pods com: kubectl get pods -n fcg'
