# Configuração compartilhada pelos scripts de infraestrutura do Azure (create-aks, stop-aks, start-aks).
# Este arquivo é "dot-sourced" (. .\config.ps1): só define variáveis, não executa nada.
# NÃO contém segredos: apenas nomes e identificadores públicos.

# --- Cluster (assinatura paga por uso: o AKS é cobrado aqui) ---------------------------------------
$SubscriptionAks = 'fcg-aks-payg'     # nome (ou ID) da assinatura onde o AKS é criado e cobrado
$ResourceGroup   = 'rg-fcg-aks'       # resource group do cluster
$Location        = 'eastus'           # região (East US)
$ClusterName     = 'aks-fcg'          # nome do cluster (escolha deste projeto; ajuste se quiser)

# --- ACR (outra assinatura, mesmo tenant) ----------------------------------------------------------
$AcrName         = 'fcgcarolina'      # fcgcarolina.azurecr.io
$SubscriptionAcr = 'Azure for Students'  # nome (ou ID) da assinatura do ACR e do Key Vault

# --- Key Vault (mesma assinatura do ACR) -----------------------------------------------------------
$KeyVaultName    = 'kv-fcg-carolina'

# --- Tenant esperado (a conta do az precisa estar logada neste tenant) -----------------------------
$TenantId        = 'ec3d901f-a4e2-4c16-b17f-b6edcd8def88'
