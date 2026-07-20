# Argo Rollouts

Controlador que interpreta o `kind: Rollout` usado em
`cluster/apps/services/*/rollout.yaml` (substitui o `Deployment` padrão
pra ganhar a estratégia canary). Instalação oficial:

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl -n argo-rollouts wait --for=condition=available --timeout=300s deployment/argo-rollouts
```

## CLI (opcional, mas facilita muito ver/promover/abortar o canary)

```bash
# Windows (via scoop) ou baixe o binário em:
# https://github.com/argoproj/argo-rollouts/releases/latest
kubectl argo rollouts version
```

## Traffic routing (canary com Ingress)

O `campaign-api` usa `trafficRouting.nginx` no `Rollout` — precisa do
`ingress-nginx` instalado no cluster:

```bash
minikube addons enable ingress   # local
```

(em cluster real, instalar via `ingress-nginx` Helm chart — fora do
escopo deste hackathon, mas o addon do minikube já entrega o mesmo
controller.)

## Acompanhando um canary em andamento

```bash
kubectl argo rollouts get rollout conexao-solidaria-campaign-api -n conexao-solidaria --watch
```

Promover manualmente (pular a pausa) ou abortar:

```bash
kubectl argo rollouts promote conexao-solidaria-campaign-api -n conexao-solidaria
kubectl argo rollouts abort conexao-solidaria-campaign-api -n conexao-solidaria
```

## Por que sem `analysis` automatizada

O exemplo de referência interno usa uma `AnalysisTemplate` que consulta
Datadog pra decidir promover ou abortar o canary sozinho. Não temos
Datadog neste projeto (observabilidade aqui é Zabbix/Grafana), então os
`Rollout` deste repo usam só steps de peso + pausa manual
(`setWeight`/`pause`) — a promoção entre os degraus é decidida por quem
está acompanhando o deploy, não automaticamente por métrica.

> `ponytail:` upgrade natural seria uma `AnalysisTemplate` baseada em
> Prometheus/Zabbix (ex.: taxa de erro HTTP via `/metrics`), adicionar
> quando o volume de deploys justificar automação.
