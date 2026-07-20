#!/usr/bin/env bash
# Configura o Zabbix via API (host group, hosts, items) - roda depois que
# zabbix-web/zabbix-server ja estao de pe. Idempotente na medida do possivel.
#
# Requisitos: curl, jq
#
# Uso:
#   ZABBIX_URL=http://localhost:8080 \
#   CAMPAIGN_API_METRICS_URL=http://conexao-solidaria-campaign-api:8080/metrics \
#   AGENT_HOST=zabbix-agent2 \
#   ./zabbix/setup.sh

set -euo pipefail

ZABBIX_URL="${ZABBIX_URL:-http://localhost:8080}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASSWORD="${ZABBIX_PASSWORD:-zabbix}"
AGENT_HOST="${AGENT_HOST:-zabbix-agent2}"
AGENT_PORT="${AGENT_PORT:-10050}"
CAMPAIGN_API_METRICS_URL="${CAMPAIGN_API_METRICS_URL:-http://conexao-solidaria-campaign-api:8080/metrics}"
DONATION_WORKER_METRICS_URL="${DONATION_WORKER_METRICS_URL:-}"

api_url="${ZABBIX_URL%/}/api_jsonrpc.php"

rpc() {
  local method="$1" params="$2" auth_field="$3"
  curl -sS -X POST "$api_url" -H 'Content-Type: application/json-rpc' -d @- <<EOF
{"jsonrpc":"2.0","method":"$method","params":$params,"id":1${auth_field}}
EOF
}

echo "Autenticando em $api_url..."
AUTH=$(rpc "user.login" "{\"username\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASSWORD\"}" "" | jq -r '.result')
if [ "$AUTH" == "null" ] || [ -z "$AUTH" ]; then
  echo "Falha no login no Zabbix. Confira ZABBIX_URL/ZABBIX_USER/ZABBIX_PASSWORD." >&2
  exit 1
fi
AUTH_FIELD=",\"auth\":\"$AUTH\""

GROUP_NAME="Conexao Solidaria"
GROUP_ID=$(rpc "hostgroup.get" "{\"filter\":{\"name\":[\"$GROUP_NAME\"]}}" "$AUTH_FIELD" | jq -r '.result[0].groupid // empty')
if [ -z "$GROUP_ID" ]; then
  echo "Criando host group '$GROUP_NAME'..."
  GROUP_ID=$(rpc "hostgroup.create" "{\"name\":\"$GROUP_NAME\"}" "$AUTH_FIELD" | jq -r '.result.groupids[0]')
else
  echo "Host group '$GROUP_NAME' ja existe (id=$GROUP_ID)."
fi

create_host_with_prometheus_item() {
  local host_name="$1" metrics_url="$2" item_key="$3" item_name="$4"

  local existing
  existing=$(rpc "host.get" "{\"filter\":{\"host\":[\"$host_name\"]}}" "$AUTH_FIELD" | jq -r '.result[0].hostid // empty')
  if [ -n "$existing" ]; then
    echo "Host '$host_name' ja existe (id=$existing), pulando criacao."
    return
  fi

  echo "Criando host '$host_name' (via agent $AGENT_HOST:$AGENT_PORT)..."
  local host_params
  host_params=$(cat <<EOF
{
  "host": "$host_name",
  "interfaces": [{"type": 1, "main": 1, "useip": 1, "ip": "$AGENT_HOST", "dns": "", "port": "$AGENT_PORT"}],
  "groups": [{"groupid": "$GROUP_ID"}],
  "items": []
}
EOF
)
  local host_id
  host_id=$(rpc "host.create" "$host_params" "$AUTH_FIELD" | jq -r '.result.hostids[0]')

  echo "Criando item '$item_name' ($item_key) no host '$host_name'..."
  local item_params
  item_params=$(cat <<EOF
{
  "name": "$item_name",
  "key_": "$item_key",
  "hostid": "$host_id",
  "type": 0,
  "value_type": 3,
  "delay": "30s",
  "interfaceid": null
}
EOF
)
  # interfaceid precisa vir da interface criada acima
  local interface_id
  interface_id=$(rpc "host.get" "{\"hostids\":[\"$host_id\"],\"selectInterfaces\":[\"interfaceid\"]}" "$AUTH_FIELD" | jq -r '.result[0].interfaces[0].interfaceid')
  item_params=$(echo "$item_params" | jq --arg iid "$interface_id" '.interfaceid = $iid')
  rpc "item.create" "$item_params" "$AUTH_FIELD" | jq .
}

# HTTP requests recebidas pela campaign-api (via plugin Prometheus do agent2,
# item key prometheus.data[<url>,<nome-da-metrica-prometheus>])
create_host_with_prometheus_item \
  "campaign-api" \
  "$CAMPAIGN_API_METRICS_URL" \
  "prometheus.data[$CAMPAIGN_API_METRICS_URL,http_requests_received_total]" \
  "HTTP Requests Total"

if [ -n "$DONATION_WORKER_METRICS_URL" ]; then
  create_host_with_prometheus_item \
    "donation-worker" \
    "$DONATION_WORKER_METRICS_URL" \
    "prometheus.data[$DONATION_WORKER_METRICS_URL,process_cpu_seconds_total]" \
    "CPU Seconds Total"
fi

# CPU/memoria dos containers/pods, via plugin Docker embutido no agent2
# (precisa do agent2 com acesso ao socket do Docker/containerd - ver k8s/zabbix-agent2-daemonset.yaml)
DOCKER_HOST_NAME="docker-containers"
existing=$(rpc "host.get" "{\"filter\":{\"host\":[\"$DOCKER_HOST_NAME\"]}}" "$AUTH_FIELD" | jq -r '.result[0].hostid // empty')
if [ -z "$existing" ]; then
  echo "Criando host '$DOCKER_HOST_NAME' com item de discovery de containers..."
  host_params=$(cat <<EOF
{
  "host": "$DOCKER_HOST_NAME",
  "interfaces": [{"type": 1, "main": 1, "useip": 1, "ip": "$AGENT_HOST", "dns": "", "port": "$AGENT_PORT"}],
  "groups": [{"groupid": "$GROUP_ID"}]
}
EOF
)
  host_id=$(rpc "host.create" "$host_params" "$AUTH_FIELD" | jq -r '.result.hostids[0]')
  interface_id=$(rpc "host.get" "{\"hostids\":[\"$host_id\"],\"selectInterfaces\":[\"interfaceid\"]}" "$AUTH_FIELD" | jq -r '.result[0].interfaces[0].interfaceid')

  item_params=$(cat <<EOF
{
  "name": "Docker containers (discovery)",
  "key_": "docker.containers",
  "hostid": "$host_id",
  "interfaceid": "$interface_id",
  "type": 0,
  "value_type": 4,
  "delay": "60s"
}
EOF
)
  rpc "item.create" "$item_params" "$AUTH_FIELD" | jq .
else
  echo "Host '$DOCKER_HOST_NAME' ja existe, pulando."
fi

echo "Pronto. Acesse o Grafana (datasource 'Zabbix' ja provisionado) para ver os paineis."
