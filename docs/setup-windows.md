# Setup guide — Windows 11

## Prerequisites

```powershell
winget install Kubernetes.minikube
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install OpenPolicyAgent.OPA
```

Install Docker Desktop from https://www.docker.com/products/docker-desktop
During setup select **Use WSL 2 instead of Hyper-V**. Wait for the whale icon
in the system tray to show "Engine running" before continuing.

Refresh PATH after installing:
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
```

Verify everything is installed:
```powershell
minikube version
kubectl version --client
helm version
docker version
opa version
```

## Quick start

```powershell
git clone <your-repo-url> opa-win11
cd opa-win11
.\bootstrap.ps1
```

Total time: ~15 minutes (mostly OpenMetadata dependencies downloading).

## Manual setup

### 1. Start Minikube

```powershell
minikube start --cpus 6 --memory 12288 --driver docker
minikube addons enable ingress
minikube addons enable ingress-dns
minikube ssh "sudo sysctl -w vm.max_map_count=262144"
```

### 2. Point Docker at Minikube (run in every new terminal before docker build)

```powershell
minikube docker-env --shell powershell | Invoke-Expression
```

### 3. Build images

```powershell
cd mock-app;  docker build -t mock-catalog:latest .;  cd ..
cd kafka-app; docker build -t kafka-opa-app:latest .; cd ..
cd demo-ui;   docker build -t demo-ui:latest .;       cd ..
```

### 4. Create secrets

```powershell
kubectl create namespace openmetadata
kubectl create namespace kafka
kubectl create secret generic mysql-secrets --from-literal=openmetadata-mysql-password=openmetadata_password -n openmetadata
kubectl create secret generic airflow-secrets --from-literal=openmetadata-airflow-password=openmetadata_password -n openmetadata
```

### 5. Deploy OPA and mock catalog

```powershell
kubectl apply -f k8s/opa-configmap.yaml
kubectl apply -f k8s/opa.yaml
kubectl apply -f k8s/mock-app.yaml
kubectl get pods -w
```

### 6. Deploy Kong

```powershell
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace
kubectl get pods -n kong -w
kubectl apply -f kong/opa-plugin.yaml
kubectl apply -f kong/ingress.yaml
kubectl set env deployment/kong-gateway -n kong KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson
```

### 7. Deploy Kafka

```powershell
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm install strimzi strimzi/strimzi-kafka-operator -n kafka --set watchNamespaces="{kafka}"
kubectl get pods -n kafka -w
kubectl apply -f kafka/kafka-opa-configmap.yaml
kubectl apply -f kafka/kafka-cluster.yaml
kubectl apply -f kafka/kafka-app.yaml
```

### 8. Deploy OpenMetadata

```powershell
helm repo add open-metadata https://helm.open-metadata.org && helm repo update
helm install openmetadata-dependencies open-metadata/openmetadata-dependencies -n openmetadata
kubectl get pods -n openmetadata -w
helm install openmetadata open-metadata/openmetadata -n openmetadata
kubectl get pods -n openmetadata -w
kubectl apply -f openmetadata/kong-opa-plugin.yaml
kubectl apply -f openmetadata/kong-ingress.yaml
kubectl apply -f openmetadata/om-proxy-svc.yaml
```

### 9. Deploy demo UI

```powershell
kubectl apply -f demo-ui/k8s.yaml
kubectl get pods -w
```

### 10. Port-forward for local access

Open five terminal tabs in VSCode (`Ctrl+Shift+``):

```powershell
kubectl port-forward svc/opa 8181:8181
kubectl port-forward svc/mock-catalog 8080:8000
kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80
kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000
kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata
```

## Testing

### Policy unit tests

```powershell
opa test .\policies .\tests -v
```

### Mock catalog

```powershell
$KONG = "http://localhost:8090"
Invoke-RestMethod -Uri "$KONG/catalog/sales_table"        -Headers @{"X-User-Role"="analyst"}    # ALLOW
Invoke-RestMethod -Uri "$KONG/catalog/customer_pii_table" -Headers @{"X-User-Role"="analyst"}    # DENY
Invoke-RestMethod -Uri "$KONG/catalog/any_table" -Method DELETE -Headers @{"X-User-Role"="admin"} # ALLOW
Invoke-RestMethod -Uri "$KONG/catalog/sales_table" -Method POST -Headers @{"X-User-Role"="viewer"} # DENY
```

### Kafka

```powershell
$KAFKA = "http://localhost:8091"
Invoke-RestMethod -Uri "$KAFKA/publish/analytics-events" -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"login"}' -ContentType "application/json"
Invoke-RestMethod -Uri "$KAFKA/publish/pii_events"       -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"test"}' -ContentType "application/json"
Invoke-RestMethod -Uri "$KAFKA/consume/analytics-events" -Headers @{"X-User-Role"="analyst"}
Invoke-RestMethod -Uri "$KAFKA/consume/analytics-events" -Headers @{"X-User-Role"="viewer"}
```

### OpenMetadata via Kong

```powershell
$password = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin"))
$body = "{`"email`":`"admin@open-metadata.org`",`"password`":`"$password`"}"
$token = Invoke-RestMethod -Uri "http://localhost:8585/api/v1/users/login" -Method POST -Body $body -ContentType "application/json"
$jwt = $token.accessToken

Invoke-RestMethod -Uri "$KONG/api/v1/tables" -Headers @{"X-User-Role"="admin"; "Authorization"="Bearer $jwt"}
Invoke-RestMethod -Uri "$KONG/api/v1/tables" -Headers @{"X-User-Role"="viewer"; "Authorization"="Bearer $jwt"}
```

## Teardown

```powershell
.\teardown.ps1
```

## Gotchas

- Use `[System.IO.File]::WriteAllText()` to write files — `Out-File` adds a BOM that breaks OPA.
- Here-strings (`@'...'@`) must have nothing after `@'` on the same line — use VSCode for multi-line files.
- Run `minikube docker-env --shell powershell | Invoke-Expression` before every `docker build`.
- `utf8NoBOM` only works in PowerShell 7+ — use `[System.IO.File]::WriteAllText()` on PS 5.1.
- Run each command on its own line — chaining with `>>` causes parser errors.
- Port-forwards die when pods restart — restart them after every `kubectl apply`.
- Kill stuck ports: `netstat -ano | Select-String ":<PORT>"` then `Stop-Process -Id <PID> -Force`.
- OPA ConfigMap mounts create symlinks — point OPA args at specific `.rego` files, not `/policies`.
- Strimzi 0.46+ dropped ZooKeeper — use KRaft mode with KafkaNodePool.
- OpenMetadata password must be Base64 encoded for the login API.
- Cross-namespace Kong routing requires an Endpoints proxy in the default namespace.
