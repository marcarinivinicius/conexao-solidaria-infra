#!/usr/bin/env bash
# Gera dados de demonstracao de verdade (nao fixtures direto no banco):
# cria campanhas, cadastra doadores e manda um fluxo continuo de doacoes +
# consultas ao painel publico via API, durante um periodo configuravel.
# Isso popula ao mesmo tempo o Postgres, o RabbitMQ e os paineis do Zabbix/
# Grafana - e o jeito mais realista de deixar o dashboard "cheio" antes de
# gravar o video.
#
# Requisitos: curl, jq
#
# Uso:
#   CAMPAIGN_API_URL=http://localhost:8081 \
#   DURATION_SECONDS=180 \
#   ./scripts/seed-demo-data.sh

set -euo pipefail

CAMPAIGN_API_URL="${CAMPAIGN_API_URL:-http://localhost:8081}"
GESTOR_EMAIL="${GESTOR_EMAIL:-gestor@conexaosolidaria.org.br}"
GESTOR_SENHA="${GESTOR_SENHA:-TrocarSenha123!}"
NUM_CAMPANHAS="${NUM_CAMPANHAS:-4}"
NUM_DOADORES="${NUM_DOADORES:-5}"
DURATION_SECONDS="${DURATION_SECONDS:-180}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-3}"

# CPF valido (mesmo algoritmo de digito verificador usado em
# ConexaoSolidaria.CampaignApi.Domain.Entities.Doador).
gen_cpf() {
  local d=()
  for _ in $(seq 1 9); do d+=($((RANDOM % 10))); done

  local soma=0 peso=10 i
  for i in 0 1 2 3 4 5 6 7 8; do soma=$((soma + d[i]*peso)); peso=$((peso-1)); done
  local resto=$((soma % 11))
  d+=($((resto < 2 ? 0 : 11-resto)))

  soma=0; peso=11
  for i in 0 1 2 3 4 5 6 7 8 9; do soma=$((soma + d[i]*peso)); peso=$((peso-1)); done
  resto=$((soma % 11))
  d+=($((resto < 2 ? 0 : 11-resto)))

  local cpf=""
  for x in "${d[@]}"; do cpf+="$x"; done
  echo "$cpf"
}

echo "Autenticando como GestorONG..."
GESTOR_TOKEN=$(curl -s -X POST "$CAMPAIGN_API_URL/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$GESTOR_EMAIL\",\"senha\":\"$GESTOR_SENHA\"}" | jq -r '.token')

if [ "$GESTOR_TOKEN" == "null" ] || [ -z "$GESTOR_TOKEN" ]; then
  echo "Falha no login do GestorONG. Confira CAMPAIGN_API_URL/GESTOR_EMAIL/GESTOR_SENHA." >&2
  exit 1
fi

TITULOS=("Natal Solidario" "Inverno Sem Frio" "Volta as Aulas" "Cesta Basica Emergencial" "Brinquedos para Todos" "Agasalho Solidario")

echo "Criando $NUM_CAMPANHAS campanhas..."
CAMPANHA_IDS=()
for i in $(seq 0 $((NUM_CAMPANHAS - 1))); do
  titulo="${TITULOS[$((i % ${#TITULOS[@]}))]} $((i + 1))"
  meta=$(( (RANDOM % 2000) + 500 ))
  resp=$(curl -s -X POST "$CAMPAIGN_API_URL/api/v1/campanhas" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $GESTOR_TOKEN" \
    -d "{\"titulo\":\"$titulo\",\"descricao\":\"Campanha de demonstracao\",\"dataInicio\":\"2026-01-01T00:00:00Z\",\"dataFim\":\"2026-12-31T00:00:00Z\",\"metaFinanceira\":$meta}")
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -n "$id" ]; then
    CAMPANHA_IDS+=("$id")
    echo "  - $titulo (meta R\$ $meta) -> $id"
  fi
done

if [ ${#CAMPANHA_IDS[@]} -eq 0 ]; then
  echo "Nenhuma campanha criada, abortando." >&2
  exit 1
fi

NOMES=("Ana Souza" "Bruno Lima" "Carla Mendes" "Diego Alves" "Elisa Rocha" "Felipe Costa" "Gabriela Dias" "Hugo Martins")

echo "Cadastrando $NUM_DOADORES doadores..."
DOADOR_TOKENS=()
for i in $(seq 0 $((NUM_DOADORES - 1))); do
  nome="${NOMES[$((i % ${#NOMES[@]}))]}"
  email="doador.demo.$i@exemplo.com"
  senha="SenhaDemo123!"
  cpf=$(gen_cpf)

  curl -s -X POST "$CAMPAIGN_API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"nomeCompleto\":\"$nome\",\"email\":\"$email\",\"cpf\":\"$cpf\",\"senha\":\"$senha\"}" > /dev/null

  token=$(curl -s -X POST "$CAMPAIGN_API_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"senha\":\"$senha\"}" | jq -r '.token // empty')

  if [ -n "$token" ]; then
    DOADOR_TOKENS+=("$token")
    echo "  - $nome ($email)"
  fi
done

if [ ${#DOADOR_TOKENS[@]} -eq 0 ]; then
  echo "Nenhum doador disponivel, abortando." >&2
  exit 1
fi

echo "Gerando trafego real por ${DURATION_SECONDS}s (consultas ao painel + doacoes a cada ${INTERVAL_SECONDS}s)..."
end_time=$(( $(date +%s) + DURATION_SECONDS ))
count=0
while [ "$(date +%s)" -lt "$end_time" ]; do
  curl -s "$CAMPAIGN_API_URL/api/v1/campanhas" > /dev/null

  doador_token="${DOADOR_TOKENS[$((RANDOM % ${#DOADOR_TOKENS[@]}))]}"
  campanha_id="${CAMPANHA_IDS[$((RANDOM % ${#CAMPANHA_IDS[@]}))]}"
  valor=$(( (RANDOM % 300) + 10 ))

  curl -s -X POST "$CAMPAIGN_API_URL/api/v1/doacoes" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $doador_token" \
    -d "{\"idCampanha\":\"$campanha_id\",\"valorDoacao\":$valor.00}" > /dev/null

  count=$((count + 1))
  sleep "$INTERVAL_SECONDS"
done

echo "Pronto. $count doacoes simuladas."
echo "Painel publico final:"
curl -s "$CAMPAIGN_API_URL/api/v1/campanhas" | jq .
