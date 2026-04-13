# OPA Policy Enforcement — Local Kubernetes Setup

## What this is

A working example of Open Policy Agent (OPA) enforcing authorization policies
across multiple services on a local Minikube cluster on Windows 11.

## Architecture

```
Client
  ├── → Kong Gateway → OPA → mock-catalog    (HTTP API / data catalog)
  └── → kafka-opa-app → OPA → Kafka          (event streaming)
                ↑
          single OPA pod
        policies/openmetadata.rego
        policies/kafka.rego
        policies/gateway.rego
```

Kong enforces policy at the network edge before requests reach the app.
The mock-catalog app enforces policy internally as a second layer.
The kafka-opa-app checks OPA before every publish and consume operation.
All three call the same OPA pod — one source of truth for all policy decisions.

## Folder structure

```
opa-win11/
├── README.md
├── teardown.ps1                  # Wipe everything cleanly
├── policies/
│   ├── openmetadata.rego         # Data catalog authorization rules
│   ├── kafka.rego                # Topic/consumer authorization rules
│   └── gateway.rego              # API route authorization rules
├── data/
│   └── roles.json                # Shared role definitions
├── tests/
│   └── authz_test.rego           # Policy unit tests
├── mock-app/
│   ├── main.py                   # FastAPI app that calls OPA on every request
│   ├── requirements.txt          # Python dependencies
│   └── Dockerfile                # Container image definition
├── kafka-app/
│   ├── main.py                   # FastAPI app wrapping Kafka produce/consume with OPA
│   ├── requirements.txt          # Python dependencies
│   └── Dockerfile                # Container image definition
├── k8s/
│   ├── opa-configmap.yaml        # OPA policies (openmetadata + kafka) loaded into K8s
│   ├── opa.yaml                  # OPA deployment + service
│   └── mock-app.yaml             # Mock catalog deployment + service
├── kafka/
│   ├── kafka-cluster.yaml        # Strimzi KRaft Kafka cluster + KafkaNodePool
│   ├── kafka-opa-configmap.yaml  # Kafka-namespace OPA policy configmap
│   └── kafka-app.yaml            # Kafka OPA app deployment + service
└── kong/
    ├── opa-plugin.yaml           # Kong Lua plugin that calls OPA pre-request
    └── ingress.yaml              # Ingress routing /catalog/* through Kong
```

## Prerequisites

- Minikube  — `winget install Kubernetes.minikube`
- kubectl   — `winget install Kubernetes.kubectl`
- Helm      — `winget install Helm.Helm`
- Docker Desktop (WSL2 backend) — https://www.docker.com/products/docker-desktop
- OPA binary — `winget install OpenPolicyAgent.OPA`

After installing, refresh PATH in PowerShell:
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
```

## Start from scratch

### 1. Start Minikube

```powershell
minikube start --cpus 4 --memory 8192 --driver docker
minikube addons enable ingress
minikube addons enable ingress-dns
```

### 2. Point Docker at Minikube (run in every new terminal before docker build)

```powershell
minikube docker-env --shell powershell | Invoke-Expression
```

### 3. Build images

```powershell
# Mock catalog app
cd mock-app
docker build -t mock-catalog:latest .
cd ..

# Kafka OPA app
cd kafka-app
docker build -t kafka-opa-app:latest .
cd ..
```

### 4. Deploy OPA and mock catalog

```powershell
kubectl apply -f k8s/opa-configmap.yaml
kubectl apply -f k8s/opa.yaml
kubectl apply -f k8s/mock-app.yaml
kubectl get pods -w
```

### 5. Deploy Kong

```powershell
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/ingress -n kong --create-namespace
kubectl get pods -n kong -w
```

### 6. Apply Kong OPA plugin

```powershell
kubectl apply -f kong/opa-plugin.yaml
kubectl apply -f kong/ingress.yaml
kubectl set env deployment/kong-gateway -n kong KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson
kubectl get pods -n kong -w
```

### 7. Deploy Kafka (Strimzi + KRaft)

```powershell
# Install Strimzi operator
kubectl create namespace kafka
helm repo add strimzi https://strimzi.io/charts
helm repo update
helm install strimzi strimzi/strimzi-kafka-operator -n kafka --set watchNamespaces="{kafka}"
kubectl get pods -n kafka -w

# Deploy Kafka cluster
kubectl apply -f kafka/kafka-opa-configmap.yaml
kubectl apply -f kafka/kafka-cluster.yaml
kubectl get pods -n kafka -w

# Deploy Kafka OPA app
kubectl apply -f kafka/kafka-app.yaml
kubectl get pods -n kafka -w
```

### 8. Port-forward for local testing

Open four dedicated terminal tabs in VSCode (Ctrl+Shift+`) and keep each running permanently:

```powershell
# Tab 1 — OPA direct access
kubectl port-forward svc/opa 8181:8181

# Tab 2 — mock catalog direct
kubectl port-forward svc/mock-catalog 8080:8000

# Tab 3 — Kong gateway
kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80

# Tab 4 — Kafka OPA app
kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000
```

Restart a port-forward any time a pod restarts — they drop automatically.

If a port is already bound:
```powershell
netstat -ano | Select-String ":<PORT>"
Stop-Process -Id <PID> -Force
```

## Testing

### Run policy unit tests (no Kubernetes needed)

```powershell
opa test .\policies .\tests -v
```

### Test OPA directly

```powershell
# Should return true
$body = '{"input":{"user":{"role":"analyst"},"action":"read","resource":"sales_table"}}'
Invoke-RestMethod -Uri "http://localhost:8181/v1/data/openmetadata/authz/allow" -Method POST -Body $body -ContentType "application/json"

# Should return false
$body = '{"input":{"user":{"role":"analyst"},"action":"read","resource":"customer_pii_table"}}'
Invoke-RestMethod -Uri "http://localhost:8181/v1/data/openmetadata/authz/allow" -Method POST -Body $body -ContentType "application/json"
```

### Test mock catalog directly (bypasses Kong)

```powershell
$APP = "http://localhost:8080"

# ALLOW — analyst reads a normal table
Invoke-RestMethod -Uri "$APP/catalog/sales_table" -Headers @{"X-User-Role"="analyst"}

# DENY — analyst reads a PII table
Invoke-RestMethod -Uri "$APP/catalog/customer_pii_table" -Headers @{"X-User-Role"="analyst"}

# ALLOW — admin deletes anything
Invoke-RestMethod -Uri "$APP/catalog/any_table" -Method DELETE -Headers @{"X-User-Role"="admin"}

# DENY — viewer tries to write
Invoke-RestMethod -Uri "$APP/catalog/sales_table" -Method POST -Headers @{"X-User-Role"="viewer"}
```

### Test through Kong gateway (full chain)

```powershell
$KONG = "http://localhost:8090"

# ALLOW — analyst reads a normal table
Invoke-RestMethod -Uri "$KONG/catalog/sales_table" -Headers @{"X-User-Role"="analyst"}

# DENY — analyst reads a PII table
Invoke-RestMethod -Uri "$KONG/catalog/customer_pii_table" -Headers @{"X-User-Role"="analyst"}

# ALLOW — admin deletes anything
Invoke-RestMethod -Uri "$KONG/catalog/any_table" -Method DELETE -Headers @{"X-User-Role"="admin"}

# DENY — viewer tries to write
Invoke-RestMethod -Uri "$KONG/catalog/sales_table" -Method POST -Headers @{"X-User-Role"="viewer"}
```

### Test Kafka produce and consume

```powershell
$KAFKA = "http://localhost:8091"

# ALLOW — analyst publishes to normal topic
Invoke-RestMethod -Uri "$KAFKA/publish/analytics-events" -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"login","user":"alice"}' -ContentType "application/json"

# DENY — analyst publishes to PII topic
Invoke-RestMethod -Uri "$KAFKA/publish/pii_events" -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"test"}' -ContentType "application/json"

# DENY — analyst publishes to internal topic
Invoke-RestMethod -Uri "$KAFKA/publish/internal_audit" -Method POST -Headers @{"X-User-Role"="analyst"} -Body '{"event":"test"}' -ContentType "application/json"

# ALLOW — analyst consumes from allowed topic
Invoke-RestMethod -Uri "$KAFKA/consume/analytics-events" -Headers @{"X-User-Role"="analyst"}

# DENY — viewer tries to consume
Invoke-RestMethod -Uri "$KAFKA/consume/analytics-events" -Headers @{"X-User-Role"="viewer"}
```

### See denial reason clearly

```powershell
try {
    Invoke-RestMethod -Uri "$KONG/catalog/customer_pii_table" -Headers @{"X-User-Role"="analyst"}
} catch {
    $_.Exception.Response.StatusCode.value__
    ($_.ErrorDetails.Message | ConvertFrom-Json).detail
}
```

## Updating policies

### Local OPA server (no Kubernetes)

```powershell
opa run --server --addr :8181 .\policies .\data
```

### Kubernetes — update and reload without restart

```powershell
kubectl apply -f k8s/opa-configmap.yaml
kubectl rollout restart deployment/opa
kubectl get pods -w
```

## Teardown

```powershell
.\teardown.ps1
```

Or manually:

```powershell
kubectl delete -f k8s/
kubectl delete -f kong/
kubectl delete -f kafka/
helm uninstall kong -n kong
helm uninstall strimzi -n kafka
kubectl delete namespace kong
kubectl delete namespace kafka
minikube stop
```

## Role permissions

| Role         | Read | Write | Delete | PII resources |
|--------------|------|-------|--------|---------------|
| admin        | yes  | yes   | yes    | yes           |
| data_steward | yes  | yes   | no     | yes           |
| analyst      | yes  | no    | no     | no            |
| viewer       | yes  | no    | no     | no            |

## Kafka topic permissions

| Role         | Publish (normal) | Publish (pii_*) | Publish (internal_*) | Consume (allowed list) |
|--------------|------------------|-----------------|----------------------|------------------------|
| admin        | yes              | yes             | yes                  | yes                    |
| data_steward | yes              | no              | no                   | no                     |
| analyst      | yes              | no              | no                   | yes                    |
| viewer       | no               | no              | no                   | no                     |

Analyst allowed consume topics: `analytics_events`, `analytics-events`, `product_clicks`, `public_feed`

## OPA endpoints

| Service      | Endpoint                                       |
|--------------|------------------------------------------------|
| OpenMetadata | POST /v1/data/openmetadata/authz/allow         |
| Kafka        | POST /v1/data/kafka/authz/allow                |
| API Gateway  | POST /v1/data/gateway/authz/allow              |

## Common Windows gotchas

- Always use `[System.IO.File]::WriteAllText()` to write files — PowerShell's
  `Out-File` adds a BOM that breaks OPA's JSON and YAML parsers.
- Here-strings (`@'...'@`) must have nothing after `@'` on the same line.
  Use VSCode to create multi-line files instead of pasting into PowerShell.
- `minikube docker-env` must be run in every new terminal before `docker build`.
- Port-forwards die when pods restart — always restart them after `kubectl apply`.
- `utf8NoBOM` encoding only works in PowerShell 7+, not Windows PowerShell 5.1.
- Run each command on its own line — chaining with `>>` causes parser errors.
- OPA ConfigMap mounts create symlinks — point OPA args at specific `.rego` files,
  not the whole `/policies` directory, to avoid multiple default rule errors.
- Kill stuck ports: `netstat -ano | Select-String ":<PORT>"` then
  `Stop-Process -Id <PID> -Force`.
- Keep four VSCode terminal tabs open permanently for port-forwards —
  closing them drops the connection silently.
- Strimzi 0.46+ dropped ZooKeeper — use KRaft mode with KafkaNodePool resources.
- Kafka version must match what Strimzi supports — check with
  `kubectl describe kafka -n kafka | Select-String "Supported versions"`.
