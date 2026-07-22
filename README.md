# conexao-solidaria-infra

Repositório **GitOps** do hackathon "Conexão Solidária": infra
compartilhada (Postgres, RabbitMQ, Zabbix, Grafana) **e** os manifests de
deploy de cada serviço (`campaign-api`, `donation-worker`), sincronizados
no cluster pelo ArgoCD com rollout canary via Argo Rollouts.

```
infra/                    # Postgres, RabbitMQ, Zabbix, Grafana, ArgoCD, Argo Rollouts
cluster/apps/services/
  campaign-api/            # Rollout (canary + Ingress), Services, Secret
  campaign-api-app.yaml     # Application do ArgoCD
  donation-worker/          # Rollout (canary por replica), Secret
  donation-worker-app.yaml  # Application do ArgoCD
```

## Fluxo de deploy (GitOps)

1. Push na `main` de `conexao-solidaria-campaign-api` ou
   `conexao-solidaria-donation-worker`.
2. O CI daquele repo builda a imagem e publica em
   `ghcr.io/marcarinivinicius/<repo>:<sha>`.
3. O mesmo CI abre um **PR aqui**, bumpando o `newTag` em
   `cluster/apps/services/<app>/kustomization.yaml` (via
   `kustomize edit set image`).
4. Alguém revisa e faz merge do PR.
5. O **ArgoCD** detecta a mudança neste repo e sincroniza automaticamente
   (`syncPolicy.automated`) — sem precisar rodar `kubectl apply` manual.
6. O **Argo Rollouts** assume a partir daí: como o recurso é `kind:
   Rollout` (não `Deployment`), a nova imagem sobe em **canary**
   (20% → pausa 30s → 60% → pausa 30s → 100%), acompanhável com
   `kubectl argo rollouts get rollout <app> -n conexao-solidaria --watch`.

Ver [`infra/argocd/README.md`](infra/argocd/README.md) e
[`infra/argo-rollouts/README.md`](infra/argo-rollouts/README.md) para
instalar os dois controllers no cluster.

Isso substitui o `kubectl apply -k k8s/` manual que os repos de serviço
usavam antes — agora o deploy só acontece via PR mergeado aqui.

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
minikube addons enable ingress   # necessario pro trafficRouting do canary da campaign-api
kubectl apply -k infra/
kubectl get pods -n conexao-solidaria -w   # espera tudo virar Running
```

Isso sobe só a infra compartilhada. Os serviços (`campaign-api`,
`donation-worker`) sobem via ArgoCD, não com `kubectl apply -k` direto —
ver [Fluxo de deploy (GitOps)](#fluxo-de-deploy-gitops) acima e
[`infra/argocd/README.md`](infra/argocd/README.md).

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

### Como o Zabbix coleta as métricas

As métricas HTTP das apps (`campaign-api`, `donation-worker`) são
coletadas via **HTTP agent items**: o próprio `zabbix-server` busca a URL
de `/metrics` de cada serviço direto e extrai o valor com uma regex sobre
o texto no formato Prometheus (`item.preprocessing` tipo `REGEX`). Não
depende de agente rodando no alvo nem de plugin nenhum — testamos
originalmente com o plugin Prometheus do `zabbix-agent2`, mas ele não
existe na imagem oficial `zabbix/zabbix-agent2:alpine-6.4-latest`
(`Unknown metric prometheus.data`), então não há mais nenhum
`zabbix-agent2` no cluster. As métricas do RabbitMQ (fila de doações)
vêm direto da API de management dele (`/api/queues/...`), extraídas via
`item.preprocessing` tipo `JSONPATH`.

**Sobre gráficos "picotados" em endpoints de baixo tráfego**: `campaign-api`
roda com mais de uma réplica atrás de um `Service` (round-robin). Cada
processo só expõe no seu próprio `/metrics` os endpoints que ele mesmo
recebeu — então um item que raspa um endpoint pouco chamado (ex.:
"Painel Público - Consultas") pode cair ora no pod que tem o dado, ora no
que não tem. Configuramos `error_handler=2` (valor `0` em vez de erro) pra
esses items não pararem de coletar, mas isso pode aparecer como quedas
pontuais pra `0` no gráfico — gere um pouco de tráfego real (`curl`/Swagger)
pouco antes de gravar o vídeo pra esses painéis ficarem com dados mais
recentes e "cheios". O item "Health Requests Total" não sofre disso porque
os probes de readiness/liveness do Kubernetes batem em `/health` de cada
pod individualmente o tempo todo.

**CPU/Memória por pod** não vem do Zabbix — chegamos a testar o plugin
Docker do agent2 (lendo `/var/run/docker.sock` do node), mas o driver
`docker` do minikube não expõe esse socket como um arquivo real (kubelet
rejeita o `hostPath` com `is not a file`). Use `kubectl top pods -n
conexao-solidaria` como evidência de consumo de recursos no vídeo de
demonstração.

## Ordem de subida

Este repo (infra) deve estar de pé **antes** de subir `campaign-api` e
`donation-worker` — eles esperam encontrar `postgres` e `rabbitmq`
resolvíveis por nome (Docker network / Service do k8s).
