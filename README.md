# FCG Orquestração

Repositório central de orquestração da plataforma FIAP Cloud Games. Contém o `docker-compose.yml` para execução local e os manifestos Kubernetes da infraestrutura.

## Repositórios dos microsserviços

| Serviço | Repositório |
|---------|-------------|
| Usuários | [FCG_Usuarios](https://github.com/caarolinaoliveira/FCG_Usuarios) |
| Catálogo | [FCG_Catalogo](https://github.com/caarolinaoliveira/FCG_Catalogo) |
| Pagamentos | [FCG_Pagamento](https://github.com/caarolinaoliveira/FCG_Pagamento) |
| Notificações | [FCG_Notificacoes](https://github.com/caarolinaoliveira/FCG_Notificacoes) |

## Imagens no Docker Hub

| Serviço | Imagem |
|---------|--------|
| Usuários | `carolinadso/fcg-usuarios-api:latest` |
| Catálogo | `carolinadso/fcg-catalogo-api:latest` |
| Pagamentos | `carolinadso/fcg-pagamentos-worker:latest` |
| Notificações | `carolinadso/fcg-notificacoes-worker:latest` |

## Executar com Docker Compose

```bash
docker-compose up
```

Serviços disponíveis:
- **Usuários API:** http://localhost:5101/swagger
- **Catálogo API:** http://localhost:5133/swagger
- **RabbitMQ Management:** http://localhost:15672 (guest/guest)

## Deploy no Kubernetes

### Pré-requisitos
- kubectl configurado
- Cluster local (Docker Desktop, Minikube, Kind)

### 1. Subir a infraestrutura
```bash
kubectl apply -f k8s/rabbitmq/
kubectl apply -f k8s/sqlserver/
```

### 2. Subir os microsserviços
```bash
kubectl apply -f ../FCG_Usuarios/k8s/
kubectl apply -f ../FCG_Catalogo/k8s/
kubectl apply -f ../FCG_Pagamento/k8s/
kubectl apply -f ../FCG_Notificacoes/k8s/
```

### 3. Verificar os pods
```bash
kubectl get pods
kubectl get services
```

### 4. Acessar os serviços
```bash
kubectl port-forward service/fcg-usuarios-api 5101:80
kubectl port-forward service/fcg-catalogo-api 5133:80
kubectl port-forward service/fcg-sqlserver 1433:1433
kubectl port-forward service/fcg-rabbitmq 15672:15672
```

> ⚠️ As credenciais neste repositório são exclusivas para ambiente de desenvolvimento local. Não utilize em produção.