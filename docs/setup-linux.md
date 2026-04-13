# Setup guide — Linux (Ubuntu/Debian)

## Prerequisites

### Install Docker

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Allow running docker without sudo
sudo usermod -aG docker $USER
newgrp docker
```

### Install Minikube

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64
```

### Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
```

### Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Install OPA

```bash
curl -L -o opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64_static
chmod +x opa
sudo mv opa /usr/local/bin/opa
```

### Install jq (optional but recommended)

```bash
sudo apt-get install -y jq
```

Verify everything:
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

### 1. Set vm.max_map_count permanently (required for OpenSearch)

```bash
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 2. Start Minikube

```bash
minikube start --cpus 6 --memory 12288 --driver docker
minikube addons enable ingress
minikube addons enable ingress-dns
```

### 3. Point Docker at Minikube (run in every new terminal before docker build)

```bash
eval $(minikube docker-env)
```

### 4. Build images

```bash
docker build -t mock-catalog:latest mock-app/
docker build -t kafka-opa-app:latest kafka-app/
docker build -t demo-ui:latest demo-ui/
```

### 5. Create secrets

```bash
kubectl create namespace openmetadata
kubectl create namespace kafka
kubectl create secret generic mysql-secrets --from-literal=openmetadata-mysql-password=openmetadata_password -n openmetadata
kubectl create secret generic airflow-secrets --from-literal=openmetadata-airflow-password=openmetadata_password -n openmetadata
```

### 6. Deploy OPA and mock catalog

```bash
kubectl apply -f k8s/opa-configmap.yaml
kubectl apply -f k8s/opa.yaml
kubectl apply -f k8s/mock-app.yaml
kubectl get pods -w
```

### 7. Deploy Kong

```bash
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace
kubectl get pods -n kong -w
kubectl apply -f kong/opa-plugin.yaml
kubectl apply -f kong/ingress.yaml
kubectl set env deployment/kong-gateway -n kong KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson
```

### 8. Deploy Kafka

```bash
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm install strimzi strimzi/strimzi-kafka-operator -n kafka --set watchNamespaces="{kafka}"
kubectl get pods -n kafka -w
kubectl apply -f kafka/kafka-opa-configmap.yaml
kubectl apply -f kafka/kafka-cluster.yaml
kubectl apply -f kafka/kafka-app.yaml
```

### 9. Deploy OpenMetadata

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

### 10. Deploy demo UI

```bash
kubectl apply -f demo-ui/k8s.yaml
kubectl get pods -w
```

### 11. Port-forward for local access

Open five terminal tabs:

```bash
kubectl port-forward svc/opa 8181:8181 &
kubectl port-forward svc/mock-catalog 8080:8000 &
kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80 &
kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000 &
kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata &
```

Or run each in a separate terminal without `&` to see logs.

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
PASSWORD=$(echo -n "admin" | base64 -w 0)
JWT=$(curl -s -X POST http://localhost:8585/api/v1/users/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"admin@open-metadata.org\",\"password\":\"$PASSWORD\"}" | jq -r '.accessToken')

curl -s -H "X-User-Role: admin"   -H "Authorization: Bearer $JWT" $KONG/api/v1/tables | jq
curl -s -H "X-User-Role: analyst" -H "Authorization: Bearer $JWT" $KONG/api/v1/tables | jq
curl -s -X POST -H "X-User-Role: viewer" -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" -d '{}' $KONG/api/v1/tables | jq
```

## Teardown

```bash
./teardown.sh
```

Or manually:
```bash
kubectl delete -f k8s/ -f kong/ -f kafka/ -f demo-ui/ -f openmetadata/
helm uninstall kong -n kong
helm uninstall strimzi -n kafka
helm uninstall openmetadata -n openmetadata
helm uninstall openmetadata-dependencies -n openmetadata
kubectl delete namespace kong kafka openmetadata
minikube stop
```

## Gotchas

- Always run `eval $(minikube docker-env)` before `docker build` — images built without it are invisible to Minikube.
- Set `vm.max_map_count=262144` permanently in `/etc/sysctl.conf` — OpenSearch will crash-loop without it.
- `minikube ssh "sudo sysctl -w vm.max_map_count=262144"` only lasts until Minikube restarts; the sysctl.conf approach is permanent.
- If Docker requires sudo, add your user to the docker group: `sudo usermod -aG docker $USER` then log out and back in.
- Port-forwards die when pods restart — restart them after every `kubectl apply`.
- Kill a stuck port: `fuser -k <PORT>/tcp` or `lsof -ti:<PORT> | xargs kill -9`
- On Ubuntu 22.04+ the `base64` command requires `-w 0` to avoid line wrapping in the OpenMetadata password encoding.
- OPA ConfigMap mounts create symlinks — point OPA args at specific `.rego` files, not `/policies`.
- Strimzi 0.46+ dropped ZooKeeper — use KRaft mode with KafkaNodePool.
- OpenMetadata password must be Base64 encoded: `echo -n "admin" | base64 -w 0`
- Cross-namespace Kong routing requires an Endpoints proxy in the default namespace.
