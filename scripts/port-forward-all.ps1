# Sobe todos os port-forwards do Conexao Solidaria de uma vez, como
# processos independentes (Start-Process, nao Start-Job - job fica preso
# ao processo do PowerShell que o criou e morre junto quando ele fecha).
# Precisa ser refeito sempre que o pod atras do Service for substituido
# (canary, restart, minikube stop/start) - e exatamente pra isso que esse
# script existe: um comando so em vez de cinco.
#
# Uso:
#   .\scripts\port-forward-all.ps1
#   Get-Process kubectl                              # ver quais estao de pe
#   Get-Process kubectl | Stop-Process -Force         # derrubar todos

Get-Process kubectl -ErrorAction SilentlyContinue | Stop-Process -Force

$forwards = @(
    "port-forward -n conexao-solidaria svc/conexao-solidaria-campaign-api-svc-stable 8081:8080",
    "port-forward -n conexao-solidaria svc/grafana 3000:3000",
    "port-forward -n conexao-solidaria svc/zabbix-web 8080:8080",
    "port-forward -n conexao-solidaria svc/rabbitmq 15672:15672",
    "port-forward -n argocd svc/argocd-server 8082:443"
)

foreach ($args in $forwards) {
    Start-Process kubectl -ArgumentList $args -WindowStyle Hidden
    Write-Output "Iniciado: kubectl $args"
}

Write-Output "`nSwagger:  http://localhost:8081/swagger"
Write-Output "Scalar:   http://localhost:8081/scalar/v1"
Write-Output "Grafana:  http://localhost:3000 (admin/admin)"
Write-Output "Zabbix:   http://localhost:8080 (Admin/zabbix)"
Write-Output "RabbitMQ: http://127.0.0.1:15672"
Write-Output "ArgoCD:   https://localhost:8082"
Write-Output "`nSe algum pod for substituido (rollout/restart), rode este script de novo."
