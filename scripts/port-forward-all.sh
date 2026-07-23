#!/usr/bin/env bash
# Sobe todos os port-forwards do Conexao Solidaria de uma vez, em
# background. Precisa ser refeito sempre que o pod atras do Service for
# substituido (canary, restart, minikube stop/start) - e exatamente pra
# isso que esse script existe: um comando so em vez de cinco.
#
# Uso:
#   ./scripts/port-forward-all.sh
#   pkill -f "kubectl port-forward"   # derrubar todos

set -euo pipefail

LOG_DIR="${TMPDIR:-/tmp}"

kubectl port-forward -n conexao-solidaria svc/conexao-solidaria-campaign-api-svc-stable 8081:8080 > "$LOG_DIR/pf-api.log" 2>&1 &
kubectl port-forward -n conexao-solidaria svc/grafana 3000:3000 > "$LOG_DIR/pf-grafana.log" 2>&1 &
kubectl port-forward -n conexao-solidaria svc/zabbix-web 8080:8080 > "$LOG_DIR/pf-zabbix.log" 2>&1 &
kubectl port-forward -n conexao-solidaria svc/rabbitmq 15672:15672 > "$LOG_DIR/pf-rabbit.log" 2>&1 &
kubectl port-forward -n argocd svc/argocd-server 8082:443 > "$LOG_DIR/pf-argocd.log" 2>&1 &
disown -a

echo "Swagger:  http://localhost:8081/swagger"
echo "Grafana:  http://localhost:3000 (admin/admin)"
echo "Zabbix:   http://localhost:8080 (Admin/zabbix)"
echo "RabbitMQ: http://127.0.0.1:15672"
echo "ArgoCD:   https://localhost:8082"
echo ""
echo "Se algum pod for substituido (rollout/restart), rode este script de novo."
