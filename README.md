# OPA Policy Enforcement — Local Kubernetes Setup

## What this is

A working example of Open Policy Agent (OPA) enforcing authorization policies
across multiple services on a local Minikube cluster on Windows 11. Includes
a no-code interactive demo UI for presenting to non-technical audiences.

## Architecture

```
Client
  ├── → Kong Gateway → OPA → mock-catalog       (HTTP API / data catalog)
  ├── → kafka-opa-app → OPA → Kafka             (event streaming)
  ├── → Kong Gateway → OPA → OpenMetadata       (real data catalog)
  └── → Kong Gateway → demo-ui                  (interactive demo)
                ↑
          single OPA pod
        policies/openmetadata.rego
        policies/kafka.rego
        policies/gateway.rego
```

## Folder structure

```
opa-win11/
├── README.md
├── bootstrap.ps1                 # One-command full stack setup
├── teardown.ps1                  # Wipe everything cleanly
├── .gitignore
├── policies/
│   ├── openmetadata.rego         # Data catalog authorization rules
│   ├── kafka.rego                # Topic/consumer authorization rules
│   └── gateway.rego              # API route authorization rules
├── data/
│   └── roles.json                # Shared role definitions
├── tests/
│   └── authz_test.rego           # Policy unit tests
├── mock-app/
│   ├── main.py                   # FastAPI app — calls OPA on every request
│   ├── requirements.txt
│   └── Dockerfile
├── kafka-app/
│   ├── main.py                   # FastAPI app — wraps Kafka with OPA checks
│   ├── requirements.txt
│   └── Dockerfile
├── demo-ui/
│   ├── index.html                # Interactive policy demo (no-code UI)
│   ├── nginx.conf                # Nginx config
│   ├── Dockerfile
│   └── k8s.yaml                  # Deployment + Service + Ingress
├── k8s/
│   ├── opa-configmap.yaml        # OPA policies loaded into Kubernetes
│   ├── opa.yaml                  # OPA deployment + service
│   └── mock-app.yaml             # Mock catalog deployment + service
├── kafka/
│   ├── kafka-cluster.yaml        # Strimzi KRaft Kafka cluster
│   ├── kafka-opa-configmap.yaml  # Kafka-namespace OPA policy
│   └── kafka-app.yaml            # Kafka OPA app deployment + service
├── kong/
│   ├── opa-plugin.yaml           # Kong Lua plugin — calls OPA pre-request
│   └── ingress.yaml              # Ingress routing /catalog/* through Kong
└── openmetadata/
    ├── kong-opa-plugin.yaml      # Kong plugin for OpenMetadata namespace
    ├── kong-ingress.yaml         # Ingress routing /api/v1/* through Kong
    └── om-proxy-svc.yaml         # Cross-namespace service proxy
```

## Prerequisites

Install these before running bootstrap:

```powershell
winget install Kubernetes.minikube
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install OpenPolicyAgent.OPA
# Docker Desktop — https://www.docker.com/products/docker-desktop
```

Refresh PATH after installing:
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
```

## Quick start (new machine)

```powershell
git clone <your-repo-url> opa-win11
cd opa-win11
.\bootstrap.ps1
```

The bootstrap script handles everything automatically:
- Starts Minikube with correct resources
- Builds all Docker images inside Minikube
- Creates required Kubernetes secrets
- Deploys OPA, mock app, Kong, Kafka, OpenMetadata, demo UI
- Runs all policy unit tests
- Prints all access URLs when done

**Total time: ~15 minutes** (mostly OpenMetadata dependencies downloading)

## Manual setup

### 1. Start Minikube

```powershell
minikube start --cpus 6 --memory 12288 --driver docker
minikube addons enable ingress
minikube addons enable ingress-dns
minikube ssh "sudo sysctl -w vm.max_map_count=262144"
```

### 2. Point Docker at Minikube (run in every new terminal)

```powershell
minikube docker-env --shell powershell | Invoke-Expression
```

### 3. Build images

```powershell
cd mock-app;    docker build -t mock-catalog:latest .;   cd ..
cd kafka-app;   docker build -t kafka-opa-app:latest .;  cd ..
cd demo-ui;     docker build -t demo-ui:latest .;        cd ..
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
kubectl get pods -n openmetadata -w   # wait for mysql + opensearch
helm install openmetadata open-metadata/openmetadata -n openmetadata
kubectl get pods -n openmetadata -w   # wait for openmetadata pod
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

Open four dedicated terminal tabs in VSCode (`Ctrl+Shift+``):

```powershell
# Tab 1 — OPA
kubectl port-forward svc/opa 8181:8181

# Tab 2 — mock catalog
kubectl port-forward svc/mock-catalog 8080:8000

# Tab 3 — Kong (gateway to everything)
kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80

# Tab 4 — Kafka app
kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000

# Tab 5 — OpenMetadata direct
kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata
```

## Access URLs

| Service | URL |
|---------|-----|
| Demo UI | http://localhost:8090/demo |
| OpenMetadata | http://localhost:8585 |
| Mock catalog (direct) | http://localhost:8080 |
| Kong gateway | http://localhost:8090 |
| Kafka app | http://localhost:8091 |
| OPA API | http://localhost:8181/v1/data |

OpenMetadata login: `admin@open-metadata.org` / `admin`

## Testing

### Policy unit tests

```powershell
opa test .\policies .\tests -v
```

### Mock catalog (via Kong)

```powershell
$KONG = "http://localhost:8090"
Invoke-RestMethod -Uri "$KONG/catalog/sales_table"          -Headers @{"X-User-Role"="analyst"}   # ALLOW
Invoke-RestMethod -Uri "$KONG/catalog/customer_pii_table"   -Headers @{"X-User-Role"="analyst"}   # DENY
Invoke-RestMethod -Uri "$KONG/catalog/any_table" -Method DELETE -Headers @{"X-User-Role"="admin"} # ALLOW
Invoke-RestMethod -Uri "$KONG/catalog/sales_table" -Method POST -Headers @{"X-User-Role"="viewer"} # DENY
```

### Kafka

```powershell
$KAFKA = "http://localhost:8091"
Invoke-RestMethod -Uri "$KAFKA/publish/analytics-events" -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"login"}' -ContentType "application/json"  # ALLOW
Invoke-RestMethod -Uri "$KAFKA/publish/pii_events"       -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"test"}' -ContentType "application/json"   # DENY
Invoke-RestMethod -Uri "$KAFKA/consume/analytics-events"              -Headers @{"X-User-Role"="analyst"}  # ALLOW
Invoke-RestMethod -Uri "$KAFKA/consume/analytics-events"              -Headers @{"X-User-Role"="viewer"}   # DENY
```

### OpenMetadata via Kong

```powershell
# Get JWT token first
$password = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin"))
$body = "{`"email`":`"admin@open-metadata.org`",`"password`":`"$password`"}"
$token = Invoke-RestMethod -Uri "http://localhost:8585/api/v1/users/login" -Method POST -Body $body -ContentType "application/json"
$jwt = $token.accessToken

# Test through Kong
Invoke-RestMethod -Uri "$KONG/api/v1/tables" -Headers @{"X-User-Role"="admin";    "Authorization"="Bearer $jwt"}  # ALLOW
Invoke-RestMethod -Uri "$KONG/api/v1/tables" -Headers @{"X-User-Role"="analyst";  "Authorization"="Bearer $jwt"}  # ALLOW
Invoke-RestMethod -Uri "$KONG/api/v1/tables" -Method POST -Headers @{"X-User-Role"="viewer"; "Authorization"="Bearer $jwt"} -Body '{}' -ContentType "application/json"  # DENY
```

## Updating policies

```powershell
# Edit any .rego file in policies/, then:
kubectl apply -f k8s/opa-configmap.yaml
kubectl rollout restart deployment/opa
```

## Teardown

```powershell
.\teardown.ps1
```

Or manually:
```powershell
kubectl delete -f k8s/ -f kong/ -f kafka/ -f demo-ui/ -f openmetadata/
helm uninstall kong -n kong
helm uninstall strimzi -n kafka
helm uninstall openmetadata -n openmetadata
helm uninstall openmetadata-dependencies -n openmetadata
kubectl delete namespace kong kafka openmetadata
minikube stop
```

## Role permissions

| Role | Read | Write | Delete | PII |
|------|------|-------|--------|-----|
| admin | yes | yes | yes | yes |
| data_steward | yes | yes | no | yes |
| analyst | yes | no | no | no |
| viewer | yes | no | no | no |

## Kafka topic permissions

| Role | Publish (normal) | Publish (pii_*) | Publish (internal_*) | Consume (allowed list) |
|------|-----------------|-----------------|----------------------|------------------------|
| admin | yes | yes | yes | yes |
| data_steward | yes | no | no | no |
| analyst | yes | no | no | yes |
| viewer | no | no | no | no |

Analyst allowed consume topics: `analytics_events`, `analytics-events`, `product_clicks`, `public_feed`

## OPA endpoints

| Service | Endpoint |
|---------|----------|
| OpenMetadata | POST /v1/data/openmetadata/authz/allow |
| Kafka | POST /v1/data/kafka/authz/allow |
| API Gateway | POST /v1/data/gateway/authz/allow |

## Git workflow

```powershell
# Make a policy change
code policies/openmetadata.rego

# Test it
opa test .\policies .\tests -v

# Apply to running cluster
kubectl apply -f k8s/opa-configmap.yaml
kubectl rollout restart deployment/opa

# Commit
git add policies/openmetadata.rego k8s/opa-configmap.yaml
git commit -m "policy: restrict analyst access to sensitive tables"
git push
```

## Common Windows gotchas

- Use `[System.IO.File]::WriteAllText()` to write files — PowerShell's `Out-File` adds a BOM that breaks OPA.
- Here-strings (`@'...'@`) must have nothing after `@'` on the same line — use VSCode for multi-line files.
- Run `minikube docker-env --shell powershell | Invoke-Expression` before every `docker build`.
- Port-forwards die when pods restart — restart them with `kubectl port-forward`.
- `utf8NoBOM` only works in PowerShell 7+ — use `[System.IO.File]::WriteAllText()` on PS 5.1.
- Run each command on its own line — chaining with `>>` causes parser errors.
- OPA ConfigMap mounts create symlinks — point OPA args at specific `.rego` files, not the whole `/policies` directory.
- Kill stuck ports: `netstat -ano | Select-String ":<PORT>"` then `Stop-Process -Id <PID> -Force`.
- Keep VSCode terminal tabs open permanently for port-forwards.
- Strimzi 0.46+ dropped ZooKeeper — use KRaft mode with KafkaNodePool.
- Kafka version must match Strimzi support: `kubectl describe kafka -n kafka | Select-String "Supported versions"`.
- OpenMetadata password must be Base64 encoded for the login API.
- Cross-namespace Kong routing requires an ExternalName service or Endpoints proxy in the default namespace.