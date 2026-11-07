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
9. [Limitações conhecidas](#limitações-conhecidas)

## Arquitetura

| Componente | Repositório | Papel |
|---|---|---|
| `usuarios-api` | [FCG_Usuarios](https://github.com/caarolinaoliveira/FCG_Usuarios) | Cadastro, login (JWT) e publicação de `user.created` |
| `catalogo-api` | [FCG_Catalogo](https://github.com/caarolinaoliveira/FCG_Catalogo) | Jogos, pedidos, biblioteca e avaliações. **Hospeda o consumidor de `payment.processed`** |
| `pagamentos-worker` | [FCG_Pagamentos](https://github.com/caarolinaoliveira/FCG_Pagamentos) | Processa `order.placed` e publica o resultado pelo padrão Outbox |
| `notificacoes-worker` | [FCG_Notificacoes](https://github.com/caarolinaoliveira/FCG_Notificacoes) | Consome RabbitMQ e envia boas-vindas e confirmação de compra |

Infraestrutura: **SQL Server** (um banco por serviço: `FCG_Usuarios`, `FCG_Catalogo`, `FCG_Pagamentos`, criados pelas migrations no startup), **RabbitMQ**, **MongoDB** (log de eventos e avaliações), **Redis** (cache) e **Elasticsearch** (reservado para a busca fuzzy do Catálogo, ainda não usado pelas aplicações).

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
  overlays/local/              Kubernetes do Docker Desktop (imagens fcg/<app>:local)
  overlays/aks/                AKS: SecretProviderClass (Key Vault), volumes CSI, Application Routing
scripts/
  create-local-secrets.ps1     Cria os Secrets no Kubernetes local a partir do .env
infra/
  config.ps1                   Nomes e assinaturas do Azure (sem segredos)
  create-aks.ps1               Cria o cluster AKS e libera o acesso ao Key Vault
  stop-aks.ps1 / start-aks.ps1 Desliga / liga o cluster para economizar
```

## Rotas do Ingress

O Ingress não usa `host` (atende pelo IP do controlador) e **não expõe** `/health`, `/swagger` nem o painel do RabbitMQ.

| Prefixo | Serviço | Rotas |
|---|---|---|
| `/api/usuarios` | `usuarios-api` | `POST registrar`, `POST login`, `GET por-email`, `POST alterar-senha` (requer token) |
| `/api/jogos` | `catalogo-api` | `GET`, `GET {id}`, `GET buscar/{titulo}`, `POST cadastrar`, `PUT {id}`, `DELETE {id}`, `GET`/`POST {jogoId}/avaliacoes` |
| `/api/biblioteca` | `catalogo-api` | `GET {usuarioId}` |
| `/api/pedidos` | `catalogo-api` | `POST {jogoId}?usuarioId=`, `GET usuario/{usuarioId}` |

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
# 1. Gera as imagens fcg/<app>:local (a mesma etapa do compose)
docker compose build

# 2. Cria os 5 Secrets no cluster local a partir do .env (nunca grava arquivo com valores)
.\scripts\create-local-secrets.ps1

# 3. Aplica o overlay local
kubectl --context docker-desktop apply -k k8s/overlays/local
kubectl --context docker-desktop -n fcg get pods      # aguarde 9/9 Running
```

**Como o cluster enxerga as imagens locais.** O Kubernetes do Docker Desktop é provisionado com *kind* e roda em um containerd próprio, mas o Docker Desktop mantém um espelho de registry (`kind-registry-mirror`) que serve ao nó as imagens do Docker local. Por isso **não é preciso** `kind load`, registry local nem `docker push`: basta o `docker compose build`. Isso foi testado com a política de pull padrão (`IfNotPresent`) e com `Never`. Reconstrua a imagem e reinicie o Deployment (`kubectl -n fcg rollout restart deploy/<nome>`) para pegar mudanças.

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
5. **Garanta que as imagens estão no ACR** com a tag definida em `k8s/overlays/aks/kustomization.yaml` (`1.0.0`). Para outra versão: `kustomize edit set image fcgcarolina.azurecr.io/usuarios-api=fcgcarolina.azurecr.io/usuarios-api:<tag>` dentro de `k8s/overlays/aks`. **Nunca use `latest`.**
6. **Aplique e verifique:**
   ```powershell
   kubectl apply -k k8s/overlays/aks
   kubectl -n fcg get pods
   kubectl -n fcg get ingress fcg        # o ADDRESS é o IP público do Ingress
   ```
7. **Economizar:** `.\infra\stop-aks.ps1` desliga o cluster (a VM do nó deixa de ser cobrada); `.\infra\start-aks.ps1` liga de novo. Os discos (PVCs), o Load Balancer e o IP público **continuam cobrados** enquanto o cluster existir.

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

O nó `Standard_B2ms` tem 8 GB de RAM (parte reservada ao sistema e aos complementos do AKS). Os **limits de memória** dos pods permanentes somam **~5,4 GiB**; o uso real medido no ambiente local foi de ~2,8 GB.

| Pod | Request | Limit | Uso medido |
|---|---|---|---|
| sqlserver (Express, `MSSQL_MEMORY_LIMIT_MB=1536`) | 1 Gi | 2 Gi | ~1,2 Gi |
| elasticsearch (heap 384m, ML desligado) | 768 Mi | 1 Gi | ~0,8 Gi (sem carga) |
| rabbitmq | 256 Mi | 512 Mi | ~145 Mi |
| mongodb | 256 Mi | 512 Mi | ~103 Mi |
| redis | 32 Mi | 128 Mi | ~9 Mi |
| usuarios-api / catalogo-api | 192 Mi | 384 Mi | ~160 Mi |
| pagamentos-worker / notificacoes-worker | 128 Mi | 256 Mi | ~133 / ~84 Mi |

Volumes persistentes: SQL Server 5 Gi, MongoDB 2 Gi, RabbitMQ 1 Gi. Redis não tem volume (só cache) e o Elasticsearch usa `emptyDir`.

## Limitações conhecidas

Decisões conscientes, registradas aqui para não serem esquecidas:

- **Ingress sem TLS (HTTP puro).** O token JWT, as senhas de login e todo o tráfego entre o cliente e o Ingress **trafegam sem criptografia**. Para ter HTTPS é preciso um domínio e um certificado, o que acrescenta custo e configuração. **Em produção** seria preciso: registrar um domínio apontando para o IP do Ingress, instalar o `cert-manager` com um emissor Let's Encrypt (ou usar um certificado do Key Vault), adicionar a seção `tls` ao Ingress e redirecionar HTTP para HTTPS.
- **Elasticsearch sem autenticação** (`xpack.security.enabled=false`). Ele só é acessível de dentro do cluster, pelo Service `ClusterIP` `fcg-elasticsearch`; não há Ingress para ele. Quando a busca fuzzy for implementada, reavaliar: habilitar a segurança e acrescentar a senha do usuário `elastic` aos segredos do Key Vault.
- **Elasticsearch em `emptyDir`.** O índice é derivado do SQL Server e será reconstruído por uma reindexação no startup do Catálogo; se o pod for recriado ou o cluster for desligado, o índice é refeito. O limit de 1 Gi foi medido **sem carga**: reavaliar quando a busca existir.
- **SQL Server Express** no cluster: gratuito em produção, mas limitado (cerca de 10 GB por banco e ~1,4 GB de memória para cache). O compose local usa a edição Developer (somente dev/teste).
- **Um único nó e uma réplica por serviço.** Não há alta disponibilidade: uma atualização do nó ou uma falha causa indisponibilidade. É o preço do menor custo possível. O bloco `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`) evita indisponibilidade só nas atualizações de aplicação.
- **Sem monitoramento da Azure e sem agente de infraestrutura do New Relic**, para poupar custo e memória. A observabilidade das aplicações é feita pelo New Relic APM.
- **Autorização do Catálogo.** Hoje quase todos os endpoints do Catálogo são `[AllowAnonymous]`, inclusive `POST /api/jogos/cadastrar`, `PUT` e `DELETE` de jogos. Como o Ingress expõe `/api/jogos` publicamente, qualquer pessoa consegue criar, alterar e apagar jogos. Isso precisa ser tratado na aplicação.
- **Busca por título exata.** `GET /api/jogos/buscar/{titulo}` compara o título inteiro; a busca fuzzy (requisito do projeto) será feita com o Elasticsearch.
- **Ingress controller local aposentado.** O ingress-nginx usado no teste local não recebe mais atualizações (ver acima). Não afeta o AKS.
- **Mudança de segredo exige reinício dos pods** (ver "Alterar um segredo").
- **Valores antigos no histórico do git.** Credenciais usadas em fases anteriores continuam no histórico dos repositórios; use valores novos no Key Vault, principalmente o `jwt-secret`.
