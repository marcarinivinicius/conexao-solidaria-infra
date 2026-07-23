# Sobe todos os port-forwards do Conexao Solidaria de uma vez, como jobs
# em background do PowerShell (sobrevive ao fechar o comando, nao o
# terminal). Precisa ser refeito sempre que o pod atras do Service for
# substituido (canary, restart, minikube stop/start) - e exatamente pra
# isso que esse script existe: um comando so em vez de cinco.
#
# Uso:
#   .\scripts\port-forward-all.ps1
#   Get-Job                    # ver status
#   Get-Job | Stop-Job         # derrubar todos

Get-Job -Name "csolidaria-*" -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job

$forwards = @(
    @{ Name = "csolidaria-api";     Args = "port-forward -n conexao-solidaria svc/conexao-solidaria-campaign-api-svc-stable 8081:8080" },
    @{ Name = "csolidaria-grafana"; Args = "port-forward -n conexao-solidaria svc/grafana 3000:3000" },
    @{ Name = "csolidaria-zabbix";  Args = "port-forward -n conexao-solidaria svc/zabbix-web 8080:8080" },
    @{ Name = "csolidaria-rabbit";  Args = "port-forward -n conexao-solidaria svc/rabbitmq 15672:15672" },
    @{ Name = "csolidaria-argocd";  Args = "port-forward -n argocd svc/argocd-server 8082:443" }
)

foreach ($f in $forwards) {
    Start-Job -Name $f.Name -ScriptBlock {
        param($kubectlArgs)
        & kubectl $kubectlArgs.Split(" ")
    } -ArgumentList $f.Args | Out-Null
    Write-Output "Iniciado: $($f.Name)"
}

Write-Output "`nSwagger:  http://localhost:8081/swagger"
Write-Output "Grafana:  http://localhost:3000 (admin/admin)"
Write-Output "Zabbix:   http://localhost:8080 (Admin/zabbix)"
Write-Output "RabbitMQ: http://127.0.0.1:15672"
Write-Output "ArgoCD:   https://localhost:8082"
Write-Output "`nSe algum pod for substituido (rollout/restart), rode este script de novo."
