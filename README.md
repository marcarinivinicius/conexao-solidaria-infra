# conexao-solidaria-infra

Infra compartilhada do hackathon "Conexão Solidária": Postgres, RabbitMQ,
Zabbix (server + web + agent2) e Grafana. Esse repo não roda a aplicação —
só a infra que ela depende (Postgres/RabbitMQ) e o stack de observabilidade
(Zabbix + Grafana), que o PDF do desafio pede explicitamente com pods
rodando de verdade e dashboards com dados reais.

Credenciais usadas abaixo (`conexaosolidaria` / `admin` / `zabbix`) são
defaults de desenvolvimento, documentados de propósito para facilitar a
correção — não use em produção.

## Opção 1 — Docker Compose (mais rápido para dev do dia a dia)

```bash
docker compose up -d
```

Sobe:

| Serviço | Acesso |
|---|---|
| Postgres | `localhost:5432` (user/senha/db: `conexaosolidaria`) |
| RabbitMQ | AMQP `localhost:5672`, Management UI `http://localhost:15672` (`conexaosolidaria`/`conexaosolidaria`) |
| Zabbix Web | `http://localhost:8080` (login `Admin` / `zabbix`) |
| Grafana | `http://localhost:3000` (login `admin` / `admin`) |

O `conexao-solidaria-campaign-api` e o `conexao-solidaria-donation-worker`
devem se conectar na mesma network Docker externa `conexao-solidaria-net`
(criada por este compose) para resolver os hostnames `postgres` e
`rabbitmq` — cada repo de serviço já vem configurado para isso (ver README
de cada um).

Depois que os serviços estiverem publicando métricas em `/metrics`, rode:

```bash
./zabbix/setup.sh
```

para criar automaticamente (via API do Zabbix) o host group, os hosts e os
items que o dashboard do Grafana espera. Variáveis de ambiente relevantes:

```bash
ZABBIX_URL=http://localhost:8080 \
CAMPAIGN_API_METRICS_URL=http://conexao-solidaria-campaign-api:8080/metrics \
DONATION_WORKER_METRICS_URL=http://conexao-solidaria-donation-worker:8080/metrics \
./zabbix/setup.sh
```

Requer `curl` e `jq` instalados.

## Opção 2 — Minikube / Kubernetes

```bash
minikube start
kubectl apply -k k8s/
kubectl get pods -n conexao-solidaria -w   # espera tudo virar Running
```

Acesso (via NodePort, ajuste conforme seu driver do minikube — em Docker
Desktop/driver docker use `minikube service <nome> -n conexao-solidaria`):

| Serviço | NodePort |
|---|---|
| RabbitMQ Management | 30672 |
| Zabbix Web | 30080 |
| Grafana | 30300 |

```bash
minikube service zabbix-web -n conexao-solidaria
minikube service grafana -n conexao-solidaria
```

Depois de tudo `Running`, rode o mesmo `zabbix/setup.sh` apontando
`ZABBIX_URL` para a URL retornada pelo `minikube service zabbix-web`.

### Sobre o painel de CPU/Memória por container

O `zabbix-agent2` roda como `DaemonSet` com o plugin **Docker** embutido,
lendo `/var/run/docker.sock` do node para reportar CPU/memória por
container (inclui os containers dos pods da aplicação). Isso só funciona
se o node do cluster expõe esse socket (verdadeiro no driver `docker` do
minikube; **não** funciona em nodes containerd puro). Se o painel
"Containers Docker" ficar vazio no Grafana, use `kubectl top pods -n
conexao-solidaria` como evidência alternativa de consumo de recursos no
vídeo de demonstração — o painel de métricas HTTP (via plugin Prometheus
do agent2, item `prometheus.data`) não depende disso e sempre funciona.

## Ordem de subida

Este repo (infra) deve estar de pé **antes** de subir `campaign-api` e
`donation-worker` — eles esperam encontrar `postgres` e `rabbitmq`
resolvíveis por nome (Docker network / Service do k8s).
