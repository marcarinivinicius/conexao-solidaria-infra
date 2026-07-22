#!/usr/bin/env bash
# Configura o Zabbix via API (host group, hosts, items) - roda depois que
# zabbix-web/zabbix-server ja estao de pe. Idempotente na medida do possivel.
#
# Usa "HTTP agent items": o proprio zabbix-server busca a URL direto (sem
# precisar de um Zabbix agent rodando no alvo, nem de plugins especiais):
#   - /metrics (formato Prometheus) das apps -> extraido via REGEX
#   - API de management do RabbitMQ (JSON)   -> extraido via JSONPATH
#
# Requisitos: curl, jq
#
# Uso:
#   ZABBIX_URL=http://localhost:8080 \
#   CAMPAIGN_API_METRICS_URL=http://conexao-solidaria-campaign-api-svc-stable:8080/metrics \
#   DONATION_WORKER_METRICS_URL=http://conexao-solidaria-donation-worker-svc:8080/metrics \
#   RABBITMQ_API_URL=http://rabbitmq:15672/api \
#   RABBITMQ_QUEUE=conexao-solidaria.doacoes.donation-worker \
#   ./zabbix/setup.sh

set -euo pipefail

ZABBIX_URL="${ZABBIX_URL:-http://localhost:8080}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASSWORD="${ZABBIX_PASSWORD:-zabbix}"
CAMPAIGN_API_METRICS_URL="${CAMPAIGN_API_METRICS_URL:-http://conexao-solidaria-campaign-api-svc-stable:8080/metrics}"
DONATION_WORKER_METRICS_URL="${DONATION_WORKER_METRICS_URL:-http://conexao-solidaria-donation-worker-svc:8080/metrics}"
RABBITMQ_API_URL="${RABBITMQ_API_URL:-http://rabbitmq:15672/api}"
RABBITMQ_QUEUE="${RABBITMQ_QUEUE:-conexao-solidaria.doacoes.donation-worker}"
RABBITMQ_USER="${RABBITMQ_USER:-conexaosolidaria}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-conexaosolidaria}"

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

item_exists() {
  local host_id="$1" item_key="$2"
  rpc "item.get" "{\"hostids\":[\"$host_id\"],\"filter\":{\"key_\":\"$item_key\"}}" "$AUTH_FIELD" | jq -r '.result[0].itemid // empty'
}

# HTTP agent item lendo texto no formato Prometheus (/metrics), com um
# valor extraido via regex.
create_regex_item() {
  local host_id="$1" item_key="$2" item_name="$3" url="$4" regex_pattern="$5"

  local existing; existing=$(item_exists "$host_id" "$item_key")
  if [ -n "$existing" ]; then
    echo "Item '$item_key' ja existe (id=$existing), pulando."
    return
  fi

  echo "Criando item '$item_name' ($item_key)..."
  local item_params
  item_params=$(jq -n \
    --arg hostid "$host_id" --arg key "$item_key" --arg name "$item_name" \
    --arg url "$url" --arg pattern "$regex_pattern" \
    '{
      name: $name, key_: $key, hostid: $hostid,
      type: 19, url: $url, value_type: 0, delay: "30s",
      preprocessing: [
        # error_handler=2 (Set value to 0): com >1 replica atras do Service,
        # o scrape cai round-robin em pods diferentes - um endpoint pouco
        # usado pode nao aparecer no /metrics do pod que respondeu essa vez
        # (cada processo so expoe as combinacoes de label que ele mesmo
        # observou). Sem isso o item vai pra estado de erro e some do
        # Grafana toda vez que a raspagem cai no pod "errado".
        { type: 5, params: ($pattern + "\n\\1"), error_handler: 2, error_handler_params: "0" }
      ]
    }')
  rpc "item.create" "$item_params" "$AUTH_FIELD" | jq .
}

# HTTP agent item lendo JSON (API de management do RabbitMQ), com um
# valor extraido via JSONPath.
create_jsonpath_item() {
  local host_id="$1" item_key="$2" item_name="$3" url="$4" jsonpath="$5"

  local existing; existing=$(item_exists "$host_id" "$item_key")
  if [ -n "$existing" ]; then
    echo "Item '$item_key' ja existe (id=$existing), pulando."
    return
  fi

  echo "Criando item '$item_name' ($item_key)..."
  local item_params
  item_params=$(jq -n \
    --arg hostid "$host_id" --arg key "$item_key" --arg name "$item_name" \
    --arg url "$url" --arg jsonpath "$jsonpath" \
    --arg user "$RABBITMQ_USER" --arg pass "$RABBITMQ_PASSWORD" \
    '{
      name: $name, key_: $key, hostid: $hostid,
      type: 19, url: $url, value_type: 0, delay: "30s",
      authtype: 1, username: $user, password: $pass,
      preprocessing: [
        { type: 12, params: $jsonpath, error_handler: 0, error_handler_params: "" }
      ]
    }')
  rpc "item.create" "$item_params" "$AUTH_FIELD" | jq .
}

# --- campaign-api: metricas de negocio (nao so /health) ---
CAMPAIGN_HOST_ID=$(ensure_host "campaign-api")

create_regex_item \
  "$CAMPAIGN_HOST_ID" "campaignapi.health.requests.total" "Health Requests Total" \
  "$CAMPAIGN_API_METRICS_URL" \
  'http_request_duration_seconds_count\{[^}]*endpoint="/health"[^}]*\}\s+([0-9.]+)'

create_regex_item \
  "$CAMPAIGN_HOST_ID" "campaignapi.campanhas.requests.total" "Painel Publico - Consultas" \
  "$CAMPAIGN_API_METRICS_URL" \
  'http_request_duration_seconds_count\{[^}]*endpoint="api/v1/campanhas"[^}]*\}\s+([0-9.]+)'

create_regex_item \
  "$CAMPAIGN_HOST_ID" "campaignapi.doacoes.requests.total" "Doacoes Registradas" \
  "$CAMPAIGN_API_METRICS_URL" \
  'http_request_duration_seconds_count\{[^}]*endpoint="api/v1/doacoes"[^}]*\}\s+([0-9.]+)'

# --- donation-worker ---
WORKER_HOST_ID=$(ensure_host "donation-worker")

create_regex_item \
  "$WORKER_HOST_ID" "donationworker.health.requests.total" "Health Requests Total" \
  "$DONATION_WORKER_METRICS_URL" \
  'http_request_duration_seconds_count\{[^}]*endpoint="/health"[^}]*\}\s+([0-9.]+)'

# --- RabbitMQ: metricas da fila de doacoes, direto da API de management ---
RABBITMQ_HOST_ID=$(ensure_host "rabbitmq")
QUEUE_URL_ENCODED=$(printf '%s' "$RABBITMQ_QUEUE" | jq -sRr @uri)
QUEUE_API_URL="${RABBITMQ_API_URL%/}/queues/%2f/${QUEUE_URL_ENCODED}"

create_jsonpath_item \
  "$RABBITMQ_HOST_ID" "rabbitmq.queue.messages_ready" "Fila de Doacoes - Mensagens na Fila" \
  "$QUEUE_API_URL" '$.messages_ready'

create_jsonpath_item \
  "$RABBITMQ_HOST_ID" "rabbitmq.queue.consumers" "Fila de Doacoes - Consumidores Ativos" \
  "$QUEUE_API_URL" '$.consumers'

create_jsonpath_item \
  "$RABBITMQ_HOST_ID" "rabbitmq.queue.published_total" "Fila de Doacoes - Mensagens Publicadas (total)" \
  "$QUEUE_API_URL" '$.message_stats.publish'

create_jsonpath_item \
  "$RABBITMQ_HOST_ID" "rabbitmq.queue.delivered_total" "Fila de Doacoes - Mensagens Entregues (total)" \
  "$QUEUE_API_URL" '$.message_stats.deliver'

# CPU/memoria por pod nao vem do Zabbix - use `kubectl top pods -n
# conexao-solidaria` como evidencia de consumo de recursos no video de
# demonstracao.

echo "Pronto. Acesse o Grafana (datasource 'Zabbix' ja provisionado) para ver os paineis."
