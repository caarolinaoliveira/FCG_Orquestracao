# FCG Orquestração

Repositório de orquestração da plataforma **FIAP Cloud Games** (Pós Tech .NET, Fase 4). Reúne tudo o que é necessário para subir os microsserviços juntos: o `docker-compose` local, os manifestos Kubernetes (Kustomize) para o Kubernetes do Docker Desktop e para o AKS, e os scripts de infraestrutura do Azure.

> A versão da Fase 3 (Kong, LocalStack, Lambda/SQS) está na tag `fase-3` dos repositórios.

## Sumário

1. [Arquitetura](#arquitetura)
2. [Estrutura do repositório](#estrutura-do-repositório)
3. [Rotas do Ingress](#rotas-do-ingress)
4. [Rodar com Docker Compose](#rodar-com-docker-compose)
5. [Rodar no Kubernetes local (Docker Desktop)](#rodar-no-kubernetes-local-docker-desktop)
6. [Criar a infraestrutura no Azure (AKS)](#criar-a-infraestrutura-no-azure-aks)
7. [Segredos: do Key Vault ao pod](#segredos-do-key-vault-ao-pod)
8. [Orçamento de recursos do nó](#orçamento-de-recursos-do-nó)
9. [NGINX do Application Routing: suporte até 30/11/2026](#nginx-do-application-routing-suporte-até-30112026)
10. [Limitações conhecidas](#limitações-conhecidas)

## Arquitetura

| Componente | Repositório | Papel |
|---|---|---|
| `usuarios-api` | [FCG_Usuarios](https://github.com/caarolinaoliveira/FCG_Usuarios) | Cadastro, login (JWT) e publicação de `user.created` |
| `catalogo-api` | [FCG_Catalogo](https://github.com/caarolinaoliveira/FCG_Catalogo) | Jogos, pedidos, biblioteca e avaliações. **Hospeda o consumidor de `payment.processed`** |
| `pagamentos-worker` | [FCG_Pagamentos](https://github.com/caarolinaoliveira/FCG_Pagamentos) | Processa `order.placed` e publica o resultado pelo padrão Outbox |
| `notificacoes-worker` | [FCG_Notificacoes](https://github.com/caarolinaoliveira/FCG_Notificacoes) | Consome RabbitMQ e envia boas-vindas e confirmação de compra |

Infraestrutura: **SQL Server** (um banco por serviço: `FCG_Usuarios`, `FCG_Catalogo`, `FCG_Pagamentos`, criados pelas migrations no startup), **RabbitMQ**, **MongoDB** (log de eventos e avaliações), **Redis** (cache) e **Elasticsearch** (índice da busca fuzzy do Catálogo, `GET /api/jogos/search`; é derivado do SQL Server e reconstruído pelo próprio Catálogo).

```
                    ┌──────────────── Ingress (NGINX) ────────────────┐
                    │  /api/usuarios            /api/jogos|biblioteca|pedidos │
                    ▼                                    ▼
              usuarios-api                         catalogo-api ◄────────────┐
                    │ user.created                       │ order.placed       │ payment.processed
                    ▼                                    ▼                    │
                         ┌──────────── RabbitMQ ────────────┐                 │
                         └────┬─────────────────────┬───────┘                 │
                              ▼                     ▼                         │
                     notificacoes-worker      pagamentos-worker ──────────────┘
                              ▲                     │ payment.processed.notificacoes
                              └─────────────────────┘
```

Observações de arquitetura:

- Cada fila tem DLQ (`<fila>.dlq`) via exchange `dlx`. Mensagens malformadas vão direto para a DLQ; falhas transitórias têm retry com backoff e circuit breaker.
- **O `FCG.Catalogo.Worker` NÃO é implantado.** O consumidor de `payment.processed` já roda dentro da API do Catálogo; implantar o Worker também faria as duas cópias disputarem as mesmas mensagens.
- Observabilidade: **New Relic APM** nas APIs e workers (o agente de infraestrutura do New Relic **não** é usado, para poupar memória do nó).
- Kong, Konga, LocalStack, SQS e Lambda **não fazem mais parte** do projeto.

## Estrutura do repositório

```
docker-compose.yaml            Ambiente local completo (infra + 4 aplicações)
.env.example                   Variáveis do compose, com valores FALSOS (copie para .env)
k8s/
  base/                        Manifestos comuns: infra, aplicações, Services, Ingress
  overlays/local/              Kubernetes do Docker Desktop (imagens fcg/<app>:<tag do build>)
  overlays/aks/                AKS: SecretProviderClass (Key Vault), volumes CSI, Application Routing
scripts/
  deploy-local.ps1             Build com tag única + Secrets + aplica o overlay local (uso recomendado)
  create-local-secrets.ps1     Cria os Secrets no Kubernetes local a partir do .env
infra/
  config.ps1                   Nomes e assinaturas do Azure (sem segredos)
  create-aks.ps1               Cria o cluster AKS e libera o acesso ao Key Vault
  stop-aks.ps1 / start-aks.ps1 Desliga / liga o cluster para economizar
```

## Rotas do Ingress

O Ingress não usa `host` (atende pelo IP do controlador) e **não expõe** `/health`, o Swagger do serviço de Usuários nem o painel do RabbitMQ.

| Prefixo | Serviço | Rotas |
|---|---|---|
| `/api/usuarios` | `usuarios-api` | `POST registrar`, `POST login`, `GET por-email`, `POST alterar-senha` (requer token) |
| `/api/jogos` | `catalogo-api` | `GET`, `GET {id}`, `GET buscar/{titulo}`, `GET search?q=` (busca fuzzy) (públicas); `POST cadastrar`, `PUT {id}`, `DELETE {id}` (**só role `Admin`**); `GET`/`POST {jogoId}/avaliacoes` (autenticado) |
| `/api/biblioteca` | `catalogo-api` | `GET {usuarioId}` (autenticado) |
| `/api/pedidos` | `catalogo-api` | `POST {jogoId}?usuarioId=`, `GET usuario/{usuarioId}` (autenticado) |
| `/swagger-catalogo` | `catalogo-api` | Swagger UI e definição do Catálogo (`/swagger-catalogo/index.html`, `/swagger-catalogo/v1/swagger.json`) |

O Swagger do Catálogo usa o prefixo próprio `swagger-catalogo` porque `/swagger` pertence ao serviço de Usuários e o Ingress só pode enviar cada caminho a um serviço. Ele é ligado pelo ConfigMap `catalogo-config` (`Swagger__Habilitado`, `Swagger__RoutePrefix`); para desligar, ponha `Swagger__Habilitado` em `"false"` e remova a regra do Ingress. As regras de autorização do Catálogo estão no [README do Catálogo](https://github.com/caarolinaoliveira/FCG_Catalogo#autoriza%C3%A7%C3%A3o).

As probes do Kubernetes usam `GET /health` direto no pod (porta 8080), sem passar pelo Ingress.

## Rodar com Docker Compose

Pré-requisitos: Docker Desktop e os cinco repositórios clonados **lado a lado** (`FCG_Usuarios`, `FCG_Catalogo`, `FCG_Pagamentos`, `FCG_Notificacoes`, `FCG_Orquestracao`), todos na `master`.

```bash
cd FCG_Orquestracao
cp .env.example .env        # edite o .env com os seus valores (o .env não é versionado)
docker compose up -d --build
docker compose ps           # aguarde as APIs ficarem "healthy"
```

O build usa as pastas irmãs. Se o seu layout for diferente, defina `USUARIOS_CONTEXT`, `CATALOGO_CONTEXT`, `PAGAMENTOS_CONTEXT` e `NOTIFICACOES_CONTEXT` no `.env`.

| Serviço | Endereço no host |
|---|---|
| `usuarios-api` | http://localhost:5101 (Swagger em `/swagger`) |
| `catalogo-api` | http://localhost:5133 (Swagger em `/swagger`) |
| RabbitMQ (painel) | http://localhost:15672 |
| SQL Server / MongoDB / Redis / Elasticsearch | `127.0.0.1`: 1433 / 27017 / 6379 / 9200 |

As portas da infraestrutura são publicadas **somente em `127.0.0.1`**, porque os valores locais costumam ser fracos.

**Variáveis do `.env`** (todas obrigatórias, exceto as de New Relic e de caminho de build; sem `.env` o compose recusa subir com uma mensagem clara):

| Variável | Uso |
|---|---|
| `SA_PASSWORD` | Senha do usuário `sa` do SQL Server (evite `;` e `=`: ela entra na connection string) |
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | Credenciais do RabbitMQ |
| `JWT_SECRET` | Chave de assinatura do JWT (mínimo 32 caracteres; Usuários e Catálogo usam a mesma) |
| `NEW_RELIC_ENABLED`, `NEW_RELIC_LICENSE_KEY` | Opcionais. O agente fica **desligado** por padrão no local |

**Testar o fluxo completo:**

```bash
curl -X POST http://localhost:5101/api/usuarios/registrar -H 'content-type: application/json' \
  -d '{"nome":"Maria","email":"maria@example.com","senha":"Teste@12345","confirmacaoSenha":"Teste@12345","dataNascimento":"1990-05-10"}'
docker compose logs notificacoes-worker     # deve mostrar "[EMAIL] Boas-vindas enviado..."
```

Para desligar e apagar os dados: `docker compose down -v`.

## Rodar no Kubernetes local (Docker Desktop)

Pré-requisitos: Kubernetes habilitado no Docker Desktop (contexto `docker-desktop`) e `kubectl` com Kustomize embutido.

```powershell
# Um comando: build com TAG ÚNICA, Secrets (a partir do .env) e aplicação do overlay local
.\scripts\deploy-local.ps1

kubectl --context docker-desktop -n fcg get pods      # aguarde 9/9 Running
```

Repita o `deploy-local.ps1` **a cada mudança de código**. Opções: `-Tag <tag>` (tag manual), `-SemBuild` (reaproveita imagens já construídas com a `-Tag` informada) e `-LimparImagensAntigas` (remove do nó as tags de builds anteriores).

**Como o cluster enxerga as imagens locais.** O Kubernetes do Docker Desktop é provisionado com *kind* e roda em um containerd próprio, mas o Docker Desktop mantém um espelho de registry (`kind-registry-mirror`) que serve ao nó as imagens do Docker local. Por isso **não é preciso** `kind load`, registry local nem `docker push`: basta construir a imagem com `docker compose build`.

**Por que cada build usa uma tag nova (`local-<aaaammddhhmmss>`).** O nó guarda as imagens em cache **por tag**: com a política de pull padrão (`IfNotPresent`), reconstruir a mesma tag (por exemplo `local`) e reiniciar o Deployment **não** atualiza o pod; ele continua rodando a imagem antiga em cache. Isso foi reproduzido e confirmado comparando os digests. A solução é uma tag diferente a cada build, o mesmo princípio da pipeline do AKS (uma tag por build, como o SHA do commit). O `imagePullPolicy: Always` **não resolve**: a imagem local não está em nenhum registry e o pod cairia em `ErrImagePull`.

O script faz o `docker compose build` com `IMAGE_TAG=<tag>` e gera um overlay temporário (`k8s/overlays/local-run/`, ignorado pelo git) que só define o bloco `images:` com a tag nova, o equivalente do `kustomize edit set image` da pipeline, sem alterar nenhum arquivo versionado. O mesmo `IMAGE_TAG` vale para o compose (`IMAGE_TAG=minha-tag docker compose build`); sem ele, a tag é `local`.

> Aplicar `kubectl apply -k k8s/overlays/local` direto (sem o script) usa a tag fixa `local` e sofre do problema acima a partir do segundo build.

**Acessar as APIs.** Sem controlador de Ingress, use `port-forward`:

```bash
kubectl --context docker-desktop -n fcg port-forward svc/usuarios-api 5101:80
kubectl --context docker-desktop -n fcg port-forward svc/catalogo-api 5133:80
```

Para testar as rotas pelo Ingress (as `/api/...` acima), instale um controlador. O Docker Desktop publica o `LoadBalancer` em `localhost`, então as rotas ficam em `http://localhost/api/...`:

```bash
kubectl --context docker-desktop apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml
```

> O projeto `kubernetes/ingress-nginx` foi **aposentado** pela comunidade (última versão: v1.15.1, de março de 2026). Aqui ele serve apenas para testar localmente; no AKS é usado o NGINX gerenciado do Application Routing, suportado pela Microsoft.

Para limpar tudo: `kubectl --context docker-desktop delete -k k8s/overlays/local` (remove o namespace `fcg`, os PVCs e os Secrets).

## Criar a infraestrutura no Azure (AKS)

> ### ⚠️ Crie o cluster somente depois de a pipeline estar pronta
> O AKS **gera cobrança enquanto existir** e, sem imagens publicadas no ACR (`fcgcarolina.azurecr.io`), todos os pods ficam em `ImagePullBackOff`. A ordem correta é: **(1)** pipeline de build e push das imagens para o ACR funcionando; **(2)** só então criar o cluster e aplicar o overlay. Enquanto isso, valide tudo no Docker Compose e no Kubernetes local.

**Decisões já tomadas:** AKS na assinatura `fcg-aks-payg`, resource group `rg-fcg-aks`, East US, **1 nó `Standard_B2ms`** (2 vCPUs, 8 GB), plano **Free**, sem monitoramento, sem upgrades automáticos. Menor custo possível como prioridade.

| Item | Valor |
|---|---|
| ACR | `fcgcarolina.azurecr.io` (assinatura *Azure for Students*, mesmo tenant) |
| Key Vault | `kv-fcg-carolina` (RBAC) |
| Cluster | `aks-fcg` (ajustável em `infra/config.ps1`) |
| Ingress | Application Routing (NGINX gerenciado), `ingressClassName: webapprouting.kubernetes.azure.com` |

**Passo a passo:**

1. **Pré-requisitos:** `az` instalado e logado no tenant correto (`az login --tenant <tenant>`); você precisa ser *Owner* (ou *User Access Administrator*) no ACR e no Key Vault, porque o script atribui papéis neles; o Key Vault deve usar o modelo de permissão **Azure RBAC**; os 8 segredos da [tabela abaixo](#segredos-do-key-vault-ao-pod) devem estar cadastrados.
2. **Veja o que será executado**, sem rodar nada:
   ```powershell
   .\infra\create-aks.ps1 -DryRun
   ```
3. **Crie o cluster** (cobra a partir daqui):
   ```powershell
   .\infra\create-aks.ps1
   ```
   O script cria o resource group, o cluster (com o complemento *Azure Key Vault Secrets Provider*, o *Application Routing* e acesso de pull ao ACR), baixa as credenciais e concede o papel **Key Vault Secrets User** à identidade do complemento.
4. **Preencha o Client ID da identidade do complemento.** Ele só existe depois de criar o cluster. O `create-aks.ps1` imprime o valor no final; para obtê-lo de novo:
   ```powershell
   az aks show --subscription fcg-aks-payg -g rg-fcg-aks -n aks-fcg --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv
   ```
   Troque o texto `PREENCHER-CLIENT-ID-DA-IDENTIDADE-DO-COMPLEMENTO` em `k8s/overlays/aks/secretproviderclass.yaml` por esse valor.
5. **Garanta que as imagens estão no ACR** com a tag definida em `k8s/overlays/aks/kustomization.yaml` (`1.0.0`). Para outra versão: `kustomize edit set image fcgcarolina.azurecr.io/usuarios-api=fcgcarolina.azurecr.io/usuarios-api:<tag>` dentro de `k8s/overlays/aks`. **Nunca use `latest`** e **use uma tag nova a cada build** (o SHA do commit, por exemplo): o nó do AKS também guarda imagens em cache por tag, então reutilizar uma tag pode manter o pod rodando a imagem antiga, o mesmo problema descrito na seção do Kubernetes local.
6. **Aplique e verifique:**
   ```powershell
   kubectl apply -k k8s/overlays/aks
   kubectl -n fcg get pods
   kubectl -n fcg get ingress fcg        # o ADDRESS é o IP público do Ingress
   ```
7. **Confira os recursos e o NGINX** (a conta da seção [Orçamento de recursos do nó](#orçamento-de-recursos-do-nó) tem suposições que só o cluster real confirma):
   ```powershell
   kubectl describe node                      # veja "Allocatable" e, no fim, "Allocated resources" (requests e limits somados)
   kubectl get deploy -n app-routing-system   # o controlador NGINX gerenciado; deve mostrar 1/1 (não 2/2)
   kubectl get nginxingresscontroller default -o jsonpath='{.spec.scaling}'
   ```
8. **Economizar:** `.\infra\stop-aks.ps1` desliga o cluster (a VM do nó deixa de ser cobrada); `.\infra\start-aks.ps1` liga de novo. Os discos (PVCs), o Load Balancer e o IP público **continuam cobrados** enquanto o cluster existir.

**Como os segredos chegam aos pods.** O `SecretProviderClass` `kv-fcg-carolina` lê os segredos do Key Vault e, pelo `secretObjects`, os sincroniza como Secrets do Kubernetes. Esses Secrets **só são criados quando algum pod monta o volume CSI**; por isso os 6 Deployments que consomem segredos (SQL Server, RabbitMQ e as 4 aplicações) montam o volume. Mongo, Redis e Elasticsearch não usam segredos e não dependem do Key Vault.

**Alterar um segredo:** mudar o valor no Key Vault **não reinicia** os pods. Depois de alterar, rode `kubectl -n fcg rollout restart deploy/<nome>`.

**Problemas comuns no AKS:**

| Sintoma | Causa provável |
|---|---|
| Pod em `ContainerCreating` com erro de `SecretProviderClass`/CSI | `userAssignedIdentityID` ainda é o texto de preenchimento, ou faltou o papel *Key Vault Secrets User* no cofre |
| Pod em `ImagePullBackOff` | Imagem/tag inexistente no ACR, ou o `--attach-acr` não foi concedido |
| Pod em `CreateContainerConfigError` | Secret ainda não sincronizado (nenhum pod montou o volume CSI) |

## Segredos: do Key Vault ao pod

Nenhum valor de segredo existe neste repositório. No AKS os valores vêm do Key Vault; no Kubernetes local, do `.env` (via `scripts/create-local-secrets.ps1`); no compose, do `.env`.

| Nome no Key Vault | Variável local (`.env`) | Secret do Kubernetes | Variável no pod |
|---|---|---|---|
| `sql-sa-password` | `SA_PASSWORD` | `infra-secrets` | `MSSQL_SA_PASSWORD` |
| `rabbitmq-user` | `RABBITMQ_USER` | `infra-secrets` | `RABBITMQ_DEFAULT_USER` |
| `rabbitmq-password` | `RABBITMQ_PASSWORD` | `infra-secrets` | `RABBITMQ_DEFAULT_PASS` |
| `sql-conn-usuarios` | (montada a partir de `SA_PASSWORD`) | `usuarios-secrets` | `ConnectionStrings__DefaultConnection` |
| `sql-conn-catalogo` | (montada a partir de `SA_PASSWORD`) | `catalogo-secrets` | `ConnectionStrings__DefaultConnection` |
| `sql-conn-pagamentos` | (montada a partir de `SA_PASSWORD`) | `pagamentos-secrets` | `ConnectionStrings__DefaultConnection` |
| `rabbitmq-user` | `RABBITMQ_USER` | `usuarios-`, `catalogo-`, `pagamentos-` e `notificacoes-secrets` | `RabbitMQ__Usuario` |
| `rabbitmq-password` | `RABBITMQ_PASSWORD` | idem | `RabbitMQ__Senha` |
| `jwt-secret` | `JWT_SECRET` | `usuarios-secrets` e `catalogo-secrets` | `JwtSettings__Segredo` |
| `newrelic-license-key` | `NEW_RELIC_LICENSE_KEY` | os 4 Secrets das aplicações | `NEW_RELIC_LICENSE_KEY` |

**Formato esperado das connection strings no Key Vault** (host do Service do SQL Server no cluster; um banco por serviço):

```
Server=fcg-sqlserver,1433;Database=<FCG_Usuarios|FCG_Catalogo|FCG_Pagamentos>;User Id=sa;Password=<senha-do-sa>;TrustServerCertificate=True;
```

O `jwt-secret` precisa ter **no mínimo 32 caracteres** (as APIs recusam iniciar com menos) e deve ser o mesmo para Usuários e Catálogo. Se qualquer segredo obrigatório faltar, a aplicação não inicia e o log diz qual chave está faltando.

## Orçamento de recursos do nó

O nó do AKS (`Standard_D2as_v4`) tem 2 vCPUs e 8 GB de RAM, mas nem tudo está disponível para os pods: o AKS reserva parte para o sistema. Os **requests** são o que o scheduler reserva (se a soma passar do alocável, o pod fica `Pending`); os **limits** são o teto de uso. Os requests de CPU foram reduzidos de 975 m para **460 m**, porque o uso real de CPU em repouso, medido no cluster local, foi de apenas ~31 m no total. Os requests de memória não foram alterados.

| Pod | CPU request | Memória request | Memória limit | Uso medido (memória) |
|---|---|---|---|---|
| sqlserver (Express, `MSSQL_MEMORY_LIMIT_MB=1536`) | 100 m | 1 Gi | 2 Gi | ~1,2 Gi |
| elasticsearch (heap 384m, ML desligado) | 100 m | 896 Mi | 1 Gi | ~0,8 Gi (810 Mi com 5.000 jogos e 400 buscas) |
| rabbitmq | 50 m | 256 Mi | 512 Mi | ~145 Mi |
| mongodb | 50 m | 256 Mi | 512 Mi | ~103 Mi |
| redis | 10 m | 32 Mi | 128 Mi | ~9 Mi |
| usuarios-api / catalogo-api | 50 m cada | 192 Mi cada | 384 Mi | ~160 Mi |
| pagamentos-worker / notificacoes-worker | 25 m cada | 128 Mi cada | 256 Mi | ~133 / ~84 Mi |
| **Soma dos requests** | **460 m** | **3.104 Mi (~3,0 GiB)** | 5,4 GiB (limits) | ~2,8 GB (total) |

**A conta do alocável** (uma estimativa; a confirmação real só existe depois de criar o cluster):

| | Memória | CPU |
|---|---|---|
| Capacidade do nó | 8.192 Mi | 2.000 m |
| Reserva do kubelet/AKS | −2.048 Mi (pior caso: 25%) | −100 m (reserva do AKS para 2 núcleos) |
| Limiar de despejo (eviction) | −100 Mi | |
| **Alocável** | **~6.044 Mi** | **~1.900 m** |
| Requests da aplicação e da infraestrutura | −3.104 Mi | −460 m |
| **Sobra para os pods do sistema e o NGINX** | **~2.940 Mi** | **~1.440 m** |

**Suposição sobre os pods do sistema.** CoreDNS, metrics-server, o driver CSI e o `secrets-store`, o operador do Application Routing e o próprio NGINX também têm requests, e **não foram medidos** (não é possível sem criar o cluster). Foi suposto que eles usem **até ~1,5 GiB de memória**; mesmo assim sobrariam ~1,4 GiB. Para CPU, a suposição se mostrou otimista (veja o bloco seguinte). Valide com os comandos do passo 7 de [Criar a infraestrutura no Azure](#criar-a-infraestrutura-no-azure-aks).

**CPU no AKS: ajuste do overlay.** No cluster real, dos ~1.900 m alocáveis já havia **1.886 m reservados** e o `usuarios-api` ficou `Pending` com "Insufficient cpu": além dos 460 m das aplicações e da infraestrutura, o NGINX do Application Routing reserva **500 m sozinho** e os pods do sistema do AKS consomem o restante. Por isso o overlay [`k8s/overlays/aks/cpu-requests.yaml`](k8s/overlays/aks/cpu-requests.yaml) reduz **só os requests de CPU** de quatro pods de infraestrutura, sem mexer em limits nem em memória:

| Pod | Base e local | Overlay `aks` |
|---|---|---|
| elasticsearch | 100 m | **50 m** |
| sqlserver | 100 m | **50 m** |
| mongodb | 50 m | **25 m** |
| rabbitmq | 50 m | **25 m** |

São 150 m liberados (460 m → 310 m), o que deixa ~165 m livres. Essa folga é necessária para o *rolling update*: com `maxSurge: 1`, o pod novo (50 m) sobe **antes** de o antigo sair, e sem sobra ele ficaria `Pending`. Os requests continuam acima do uso medido em repouso (~31 m no total); o limit de CPU de cada pod segue permitindo rajadas. A base e o overlay local não mudam.

Fontes: [reservas de recursos dos nós do AKS](https://learn.microsoft.com/en-us/azure/aks/node-resource-reservations) e [limites e requests no Kubernetes](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/).

Volumes persistentes: SQL Server 5 Gi, MongoDB 2 Gi, RabbitMQ 1 Gi. Redis não tem volume (só cache) e o Elasticsearch usa `emptyDir`.

## NGINX do Application Routing: suporte até 30/11/2026

O Ingress usa o NGINX gerenciado do **Application Routing** do AKS. O projeto upstream `kubernetes/ingress-nginx` foi aposentado (manutenção encerrada em março de 2026), e a Microsoft **mantém apenas correções críticas de segurança do NGINX do Application Routing até 30/11/2026**. Depois disso, ele deixa de ter suporte. Como o cluster desta entrega é **temporário**, decidiu-se manter o NGINX agora; não há ação imediata.

**Em produção**, a migração prevista é para a **Gateway API do Application Routing** (`GatewayClass` `approuting-istio`), que implanta um plano de controle **Istio** sem sidecars. A migração não exige janela de indisponibilidade, mas a Gateway API não aceita os recursos do NGINX por anotação (limite de corpo, Lua, rate limit), e cada Gateway cria HPA com no mínimo 2 réplicas, o que pesa num nó `Standard_B2ms`.

**Uma réplica do NGINX.** O padrão do complemento é `minReplicas: 2`. Com um único nó, a segunda réplica só consome CPU, então [`k8s/overlays/aks/nginx-default-controller.yaml`](k8s/overlays/aks/nginx-default-controller.yaml) ajusta o `NginxIngressController` chamado `default` (criado pelo próprio complemento) com `spec.scaling.minReplicas: 1` e `spec.scaling.maxReplicas: 2`. O `kubectl apply -k k8s/overlays/aks` do passo 6 já aplica esse ajuste. Se o cluster for criado sem o overlay, use `kubectl edit nginxingresscontroller default`.

Fontes:
- [Configurar o NGINX do Application Routing (campos do `NginxIngressController`, aviso de suporte)](https://learn.microsoft.com/en-us/azure/aks/app-routing-nginx-configuration)
- [Application Routing com a Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api)
- [Guia de migração do NGINX para a Gateway API](https://learn.microsoft.com/azure/aks/app-routing-nginx-to-gateway-api-migration)
- [Blog do AKS: atualização sobre o Application Routing e o Ingress-NGINX](https://blog.aks.azure.com/2025/11/13/ingress-nginx-update)
- [Aviso de aposentadoria AZ555839 (Message Center, cópia de terceiros)](https://mc.merill.net/message/AZ555839)
- [Aposentadoria do Ingress NGINX (Kubernetes)](https://www.kubernetes.dev/blog/2025/11/12/ingress-nginx-retirement/)

## Limitações conhecidas

Decisões conscientes, registradas aqui para não serem esquecidas:

- **Ingress sem TLS (HTTP puro).** O token JWT, as senhas de login e todo o tráfego entre o cliente e o Ingress **trafegam sem criptografia**. Para ter HTTPS é preciso um domínio e um certificado, o que acrescenta custo e configuração. **Em produção** seria preciso: registrar um domínio apontando para o IP do Ingress, instalar o `cert-manager` com um emissor Let's Encrypt (ou usar um certificado do Key Vault), adicionar a seção `tls` ao Ingress e redirecionar HTTP para HTTPS.
- **Elasticsearch sem autenticação** (`xpack.security.enabled=false`). Ele só é acessível de dentro do cluster, pelo Service `ClusterIP` `fcg-elasticsearch`; não há Ingress para ele. Em produção, habilitar a segurança e acrescentar a senha do usuário `elastic` aos segredos do Key Vault.
- **Elasticsearch em `emptyDir`.** O índice é derivado do SQL Server: o Catálogo o recria no startup e a cada 60 s compara a contagem de documentos com a do SQL. Se o pod do Elasticsearch for recriado ou o cluster for desligado, o índice é refeito sozinho. Medido com 5.000 jogos e 400 buscas, o pod ficou em ~810 Mi, dentro do limit de 1 Gi.
- **SQL Server Express** no cluster: gratuito em produção, mas limitado (cerca de 10 GB por banco e ~1,4 GB de memória para cache). O compose local usa a edição Developer (somente dev/teste).
- **Um único nó e uma réplica por serviço.** Não há alta disponibilidade: uma atualização do nó ou uma falha causa indisponibilidade. É o preço do menor custo possível. O bloco `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`) evita indisponibilidade só nas atualizações de aplicação.
- **Sem monitoramento da Azure e sem agente de infraestrutura do New Relic**, para poupar custo e memória. A observabilidade das aplicações é feita pelo New Relic APM.
- **Identidade do usuário nas rotas do Catálogo.** Criar, alterar e apagar jogos exige a role `Admin`, e biblioteca, pedidos e avaliações exigem login. Porém o token JWT só traz o e-mail e a role, **não o id do usuário**, então as rotas que recebem `usuarioId` não verificam se ele pertence a quem está logado: qualquer usuário autenticado que souber o GUID de outro pode consultar a biblioteca dele ou comprar e avaliar em seu nome. Para corrigir, o serviço de Usuários precisa colocar o id no token.
- **Não existe administrador de fábrica.** O `registrar` só atribui a role `Usuario`; um `Admin` é criado promovendo o usuário por SQL no banco `FCG_Usuarios` (ver o [README do Catálogo](https://github.com/caarolinaoliveira/FCG_Catalogo#autoriza%C3%A7%C3%A3o)).
- **Swagger do Catálogo exposto publicamente** pelo Ingress (`/swagger-catalogo`), habilitado para a demonstração. Ele documenta a API, mas não dá acesso às rotas protegidas sem token. Desligue depois da demonstração (ver "Rotas do Ingress").
- **Busca por título exata × busca fuzzy.** `GET /api/jogos/buscar/{titulo}` compara o título inteiro; a busca com tolerância a erros de digitação é `GET /api/jogos/search?q=` (Elasticsearch). Se o Elasticsearch estiver fora do ar, só ela responde `503`; o CRUD continua.
- **NGINX do Application Routing com prazo de suporte.** Veja a seção [NGINX do Application Routing: suporte até 30/11/2026](#nginx-do-application-routing-suporte-até-30112026).
- **Ingress controller local aposentado.** O ingress-nginx usado no teste local não recebe mais atualizações (ver acima). Não afeta o AKS.
- **Mudança de segredo exige reinício dos pods** (ver "Alterar um segredo").
- **Valores antigos no histórico do git.** Credenciais usadas em fases anteriores continuam no histórico dos repositórios; use valores novos no Key Vault, principalmente o `jwt-secret`.
