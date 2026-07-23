# ArgoCD

Instalação oficial (não reinventamos manifest — usamos o `install.yaml` do
próprio projeto, é o caminho suportado e mais simples de manter atualizado):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server
```

## Acessar o dashboard

Aplique o Service NodePort deste diretório (uma vez só, não faz parte do
`install.yaml` oficial — é só uma porta fixa a mais pra não depender de
`port-forward`, que cai toda vez que o pod do `argocd-server` é
substituído):

```bash
kubectl apply -f infra/argocd/nodeport-service.yaml
minikube service argocd-server-nodeport -n argocd --url   # ou https://<minikube ip>:30443
```

Se preferir `port-forward` mesmo assim (funciona igual, só não é fixo):

```bash
kubectl -n argocd port-forward svc/argocd-server 8081:443
```

Login: `admin` / senha em:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode
```

## Registrar este repositório como fonte

O ArgoCD precisa saber ler `github.com/marcarinivinicius/conexao-solidaria-infra`
(repo público, não precisa de credencial pra clonar, só se quiser evitar
rate limit anônimo do GitHub):

```bash
argocd repo add https://github.com/marcarinivinicius/conexao-solidaria-infra.git
```

## Aplicar as `Application` de cada serviço

Depois do ArgoCD instalado, aplique os manifests `Application` (não os
manifests do app em si — o ArgoCD que vai sincronizar aqueles a partir
deste repo):

```bash
kubectl apply -f cluster/apps/services/campaign-api-app.yaml
kubectl apply -f cluster/apps/services/donation-worker-app.yaml
```

A partir daí, qualquer PR mergeado em `cluster/apps/services/*` neste repo
é sincronizado automaticamente no cluster (sync automático com self-heal
configurado em cada `Application`).
