# Setup guide — macOS

## Prerequisites

Install Homebrew if you don't have it:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install all tools:
```bash
brew install minikube
brew install kubectl
brew install helm
brew install opa
brew install --cask docker
```

Open Docker Desktop from Applications and wait until the whale icon in the menu
bar shows "Docker Desktop is running" before continuing.

Verify everything is installed:
```bash
minikube version
kubectl version --client
helm version
docker version
opa version
```

## Quick start

```bash
git clone <your-repo-url> opa-win11
cd opa-win11
chmod +x bootstrap.sh
./bootstrap.sh
```

Total time: ~15 minutes (mostly OpenMetadata dependencies downloading).

## Manual setup

### 1. Start Minikube

On Apple Silicon (M1/M2/M3):
```bash
minikube start --cpus 6 --memory 12288 --driver docker
```

On Intel Mac:
```bash
minikube start --cpus 6 --memory 12288 --driver docker
```

Then enable addons and set OpenSearch kernel param:
```bash
minikube addons enable ingress
minikube addons enable ingress-dns
minikube ssh "sudo sysctl -w vm.max_map_count=262144"
```

### 2. Point Docker at Minikube (run in every new terminal before docker build)

```bash
eval $(minikube docker-env)
```

### 3. Build images

```bash
docker build -t mock-catalog:latest mock-app/
docker build -t kafka-opa-app:latest kafka-app/
docker build -t demo-ui:latest demo-ui/
```

### 4. Create secrets

```bash
kubectl create namespace openmetadata
kubectl create namespace kafka
kubectl create secret generic mysql-secrets --from-literal=openmetadata-mysql-password=openmetadata_password -n openmetadata
kubectl create secret generic airflow-secrets --from-literal=openmetadata-airflow-password=openmetadata_password -n openmetadata
```

### 5. Deploy OPA and mock catalog

```bash
kubectl apply -f k8s/opa-configmap.yaml
kubectl apply -f k8s/opa.yaml
kubectl apply -f k8s/mock-app.yaml
kubectl get pods -w
```

### 6. Deploy Kong

```bash
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace
kubectl get pods -n kong -w
kubectl apply -f kong/opa-plugin.yaml
kubectl apply -f kong/ingress.yaml
kubectl set env deployment/kong-gateway -n kong KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson
```

### 7. Deploy Kafka

```bash
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm install strimzi strimzi/strimzi-kafka-operator -n kafka --set watchNamespaces="{kafka}"
kubectl get pods -n kafka -w
kubectl apply -f kafka/kafka-opa-configmap.yaml
kubectl apply -f kafka/kafka-cluster.yaml
kubectl apply -f kafka/kafka-app.yaml
```

### 8. Deploy OpenMetadata

```bash
helm repo add open-metadata https://helm.open-metadata.org && helm repo update
helm install openmetadata-dependencies open-metadata/openmetadata-dependencies -n openmetadata
kubectl get pods -n openmetadata -w   # wait for mysql + opensearch
helm install openmetadata open-metadata/openmetadata -n openmetadata
kubectl get pods -n openmetadata -w   # wait for openmetadata pod
kubectl apply -f openmetadata/kong-opa-plugin.yaml
kubectl apply -f openmetadata/kong-ingress.yaml
kubectl apply -f openmetadata/om-proxy-svc.yaml
```

### 9. Deploy demo UI

```bash
kubectl apply -f demo-ui/k8s.yaml
kubectl get pods -w
```

### 10. Port-forward for local access

Open five terminal tabs in VSCode (`Cmd+Shift+``):

```bash
kubectl port-forward svc/opa 8181:8181
kubectl port-forward svc/mock-catalog 8080:8000
kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80
kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000
kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata
```

## Testing

### Policy unit tests

```bash
opa test ./policies ./tests -v
```

### Mock catalog

```bash
KONG="http://localhost:8090"
curl -s -H "X-User-Role: analyst" $KONG/catalog/sales_table | jq        # ALLOW
curl -s -H "X-User-Role: analyst" $KONG/catalog/customer_pii_table | jq # DENY
curl -s -X DELETE -H "X-User-Role: admin" $KONG/catalog/any_table | jq  # ALLOW
curl -s -X POST -H "X-User-Role: viewer" $KONG/catalog/sales_table | jq # DENY
```

### Kafka

```bash
KAFKA="http://localhost:8091"
curl -s -X POST -H "X-User-Role: analyst" -H "Content-Type: application/json" \
  -d '{"event":"login"}' $KAFKA/publish/analytics-events | jq   # ALLOW
curl -s -X POST -H "X-User-Role: analyst" -H "Content-Type: application/json" \
  -d '{"event":"test"}' $KAFKA/publish/pii_events | jq           # DENY
curl -s -H "X-User-Role: analyst" $KAFKA/consume/analytics-events | jq  # ALLOW
curl -s -H "X-User-Role: viewer"  $KAFKA/consume/analytics-events | jq  # DENY
```

### OpenMetadata via Kong

```bash
PASSWORD=$(echo -n "admin" | base64)
JWT=$(curl -s -X POST http://localhost:8585/api/v1/users/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"admin@open-metadata.org\",\"password\":\"$PASSWORD\"}" | jq -r '.accessToken')

curl -s -H "X-User-Role: admin"   -H "Authorization: Bearer $JWT" $KONG/api/v1/tables | jq
curl -s -H "X-User-Role: analyst" -H "Authorization: Bearer $JWT" $KONG/api/v1/tables | jq
curl -s -X POST -H "X-User-Role: viewer" -H "Authorization: Bearer $JWT" $KONG/api/v1/tables | jq
```

## Teardown

```bash
./teardown.sh
```

## Gotchas

- Always run `eval $(minikube docker-env)` before `docker build` in every new terminal.
- On Apple Silicon (M1/M2/M3) Docker images build for `arm64` — the Minikube VM also runs `arm64` so this is fine, but base images must support it. All images used here (python:3.12-slim, nginx:alpine, openpolicyagent/opa) do.
- Port-forwards die when pods restart — restart them after every `kubectl apply`.
- Kill a stuck port: `lsof -ti:<PORT> | xargs kill -9`
- If `minikube start` fails on Docker driver, make sure Docker Desktop is fully running first.
- OPA ConfigMap mounts create symlinks — point OPA args at specific `.rego` files, not `/policies`.
- Strimzi 0.46+ dropped ZooKeeper — use KRaft mode with KafkaNodePool.
- OpenMetadata password must be Base64 encoded: `echo -n "admin" | base64`
- `jq` is useful for formatting JSON responses — install with `brew install jq`.
