#!/usr/bin/env bash
# Configura o Zabbix via API (host group, hosts, items) - roda depois que
# zabbix-web/zabbix-server ja estao de pe. Idempotente na medida do possivel.
#
# Usa "HTTP agent items": o proprio zabbix-server busca a URL de /metrics
# direto (sem precisar de um Zabbix agent rodando no alvo, nem de plugins
# especiais) e extrai o valor via regex no texto Prometheus. Testado ao
# vivo - a alternativa original (plugin Prometheus do zabbix-agent2) nao
# existe na imagem oficial zabbix/zabbix-agent2:alpine-6.4-latest.
#
# Requisitos: curl, jq
#
# Uso:
#   ZABBIX_URL=http://localhost:8080 \
#   CAMPAIGN_API_METRICS_URL=http://conexao-solidaria-campaign-api-svc-stable:8080/metrics \
#   ./zabbix/setup.sh

set -euo pipefail

ZABBIX_URL="${ZABBIX_URL:-http://localhost:8080}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASSWORD="${ZABBIX_PASSWORD:-zabbix}"
CAMPAIGN_API_METRICS_URL="${CAMPAIGN_API_METRICS_URL:-http://conexao-solidaria-campaign-api-svc-stable:8080/metrics}"
DONATION_WORKER_METRICS_URL="${DONATION_WORKER_METRICS_URL:-http://conexao-solidaria-donation-worker-svc:8080/metrics}"

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

# HTTP agent items nao exigem interface de agent - o host so precisa
# existir e pertencer a um grupo.
ensure_host() {
  local host_name="$1"
  local existing
  existing=$(rpc "host.get" "{\"filter\":{\"host\":[\"$host_name\"]}}" "$AUTH_FIELD" | jq -r '.result[0].hostid // empty')
  if [ -n "$existing" ]; then
    echo "$existing"
    return
  fi

  echo "Criando host '$host_name'..." >&2
  local host_params
  host_params=$(jq -n --arg host "$host_name" --arg groupid "$GROUP_ID" \
    '{host: $host, groups: [{groupid: $groupid}], interfaces: []}')
  rpc "host.create" "$host_params" "$AUTH_FIELD" | jq -r '.result.hostids[0]'
}

create_http_agent_item() {
  local host_id="$1" item_key="$2" item_name="$3" metrics_url="$4" regex_pattern="$5"

  local existing
  existing=$(rpc "item.get" "{\"hostids\":[\"$host_id\"],\"filter\":{\"key_\":\"$item_key\"}}" "$AUTH_FIELD" | jq -r '.result[0].itemid // empty')
  if [ -n "$existing" ]; then
    echo "Item '$item_key' ja existe (id=$existing), pulando."
    return
  fi

  echo "Criando item '$item_name' ($item_key)..."
  local item_params
  item_params=$(jq -n \
    --arg hostid "$host_id" \
    --arg key "$item_key" \
    --arg name "$item_name" \
    --arg url "$metrics_url" \
    --arg pattern "$regex_pattern" \
    '{
      name: $name,
      key_: $key,
      hostid: $hostid,
      type: 19,
      url: $url,
      value_type: 0,
      delay: "30s",
      preprocessing: [
        { type: 5, params: ($pattern + "\n\\1"), error_handler: 0, error_handler_params: "" }
      ]
    }')
  rpc "item.create" "$item_params" "$AUTH_FIELD" | jq .
}

CAMPAIGN_HOST_ID=$(ensure_host "campaign-api")
create_http_agent_item \
  "$CAMPAIGN_HOST_ID" \
  "campaignapi.health.requests.total" \
  "Health Requests Total" \
  "$CAMPAIGN_API_METRICS_URL" \
  'http_request_duration_seconds_count\{[^}]*endpoint="/health"[^}]*\}\s+([0-9.]+)'

WORKER_HOST_ID=$(ensure_host "donation-worker")
create_http_agent_item \
  "$WORKER_HOST_ID" \
  "donationworker.health.requests.total" \
  "Health Requests Total" \
  "$DONATION_WORKER_METRICS_URL" \
  'http_request_duration_seconds_count\{[^}]*endpoint="/health"[^}]*\}\s+([0-9.]+)'

# CPU/memoria por pod nao vem do Zabbix - use `kubectl top pods -n
# conexao-solidaria` como evidencia de consumo de recursos no video de
# demonstracao.

echo "Pronto. Acesse o Grafana (datasource 'Zabbix' ja provisionado) para ver os paineis."
