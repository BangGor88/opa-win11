# OPA Win11 — full stack bootstrap
# Run from repo root on a fresh Windows 11 machine
# Usage: .\bootstrap.ps1

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

function Log($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function OK($msg)  { Write-Host "   $msg" -ForegroundColor Green }
function Fail($msg){ Write-Host "   ERROR: $msg" -ForegroundColor Red; exit 1 }

function Require($cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Fail "$cmd not found. Install it first:`n   winget install $(if($cmd -eq 'minikube'){'Kubernetes.minikube'}elseif($cmd -eq 'kubectl'){'Kubernetes.kubectl'}elseif($cmd -eq 'helm'){'Helm.Helm'}else{'Docker.DockerDesktop'})"
    }
    OK "$cmd found"
}

function WaitForPods($ns, $label, $timeout=180) {
    Log "Waiting for pods in namespace '$ns' ($label)..."
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        $ready = kubectl get pods -n $ns -l $label --no-headers 2>$null |
            Where-Object { $_ -match "Running" -and $_ -match "1/1|2/2" }
        if ($ready) { OK "Pods ready"; return }
        Start-Sleep 5; $elapsed += 5
        Write-Host "   ...waiting ($elapsed s)" -NoNewline
    }
    Fail "Pods did not become ready in $timeout seconds"
}

# ── 1. Prerequisites ────────────────────────────────────────────────────────
Log "Checking prerequisites..."
Require minikube
Require kubectl
Require helm
Require docker
Require opa

# ── 2. Minikube ─────────────────────────────────────────────────────────────
Log "Starting Minikube..."
$status = minikube status --format="{{.Host}}" 2>$null
if ($status -ne "Running") {
    minikube start --cpus 6 --memory 12288 --driver docker
    OK "Minikube started"
} else {
    OK "Minikube already running"
}

minikube addons enable ingress 2>$null
minikube addons enable ingress-dns 2>$null
minikube ssh "sudo sysctl -w vm.max_map_count=262144" 2>$null
OK "Addons enabled"

# ── 3. Docker env ───────────────────────────────────────────────────────────
Log "Pointing Docker at Minikube..."
minikube docker-env --shell powershell | Invoke-Expression
OK "Docker env set"

# ── 4. Build images ─────────────────────────────────────────────────────────
Log "Building mock-catalog image..."
docker build -t mock-catalog:latest "$root\mock-app"
OK "mock-catalog built"

Log "Building kafka-opa-app image..."
docker build -t kafka-opa-app:latest "$root\kafka-app"
OK "kafka-opa-app built"

Log "Building demo-ui image..."
docker build -t demo-ui:latest "$root\demo-ui"
OK "demo-ui built"

# ── 5. Create secrets ────────────────────────────────────────────────────────
Log "Creating Kubernetes secrets..."
kubectl create namespace openmetadata --dry-run=client -o yaml | kubectl apply -f - 2>$null
kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f - 2>$null

kubectl create secret generic mysql-secrets `
    --from-literal=openmetadata-mysql-password=openmetadata_password `
    -n openmetadata --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic airflow-secrets `
    --from-literal=openmetadata-airflow-password=openmetadata_password `
    -n openmetadata --dry-run=client -o yaml | kubectl apply -f -
OK "Secrets created"

# ── 6. Deploy OPA + mock app ─────────────────────────────────────────────────
Log "Deploying OPA and mock catalog..."
kubectl apply -f "$root\k8s\opa-configmap.yaml"
kubectl apply -f "$root\k8s\opa.yaml"
kubectl apply -f "$root\k8s\mock-app.yaml"
WaitForPods "default" "app=opa"
WaitForPods "default" "app=mock-catalog"
OK "OPA and mock catalog running"

# ── 7. Deploy Kong ───────────────────────────────────────────────────────────
Log "Installing Kong..."
helm repo add kong https://charts.konghq.com 2>$null
helm repo update 2>$null
$kongInstalled = helm list -n kong 2>$null | Select-String "kong"
if (-not $kongInstalled) {
    helm install kong kong/ingress -n kong --create-namespace
} else {
    OK "Kong already installed"
}
WaitForPods "kong" "app.kubernetes.io/name=gateway"

Log "Applying Kong OPA plugin..."
kubectl apply -f "$root\kong\opa-plugin.yaml"
kubectl apply -f "$root\kong\ingress.yaml"
kubectl set env deployment/kong-gateway -n kong KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson
WaitForPods "kong" "app.kubernetes.io/name=gateway"
OK "Kong configured"

# ── 8. Deploy Kafka ───────────────────────────────────────────────────────────
Log "Installing Strimzi operator..."
helm repo add strimzi https://strimzi.io/charts 2>$null
helm repo update 2>$null
$strimziInstalled = helm list -n kafka 2>$null | Select-String "strimzi"
if (-not $strimziInstalled) {
    helm install strimzi strimzi/strimzi-kafka-operator -n kafka --set watchNamespaces="{kafka}"
} else {
    OK "Strimzi already installed"
}
WaitForPods "kafka" "name=strimzi-cluster-operator"

Log "Deploying Kafka cluster..."
kubectl apply -f "$root\kafka\kafka-opa-configmap.yaml"
kubectl apply -f "$root\kafka\kafka-cluster.yaml"
kubectl apply -f "$root\kafka\kafka-app.yaml"
WaitForPods "kafka" "app=kafka-opa-app" 300
OK "Kafka running"

# ── 9. Deploy OpenMetadata ────────────────────────────────────────────────────
Log "Installing OpenMetadata dependencies..."
helm repo add open-metadata https://helm.open-metadata.org 2>$null
helm repo update 2>$null
$omDepsInstalled = helm list -n openmetadata 2>$null | Select-String "openmetadata-dependencies"
if (-not $omDepsInstalled) {
    helm install openmetadata-dependencies open-metadata/openmetadata-dependencies -n openmetadata
} else {
    OK "OpenMetadata dependencies already installed"
}
WaitForPods "openmetadata" "app=opensearch" 300
WaitForPods "openmetadata" "app=mysql" 180

Log "Installing OpenMetadata..."
$omInstalled = helm list -n openmetadata 2>$null | Select-String "^openmetadata "
if (-not $omInstalled) {
    helm install openmetadata open-metadata/openmetadata -n openmetadata
} else {
    OK "OpenMetadata already installed"
}
WaitForPods "openmetadata" "app=openmetadata" 300
OK "OpenMetadata running"

Log "Applying OpenMetadata Kong ingress..."
kubectl apply -f "$root\openmetadata\kong-opa-plugin.yaml"
kubectl apply -f "$root\openmetadata\kong-ingress.yaml"
kubectl apply -f "$root\openmetadata\om-proxy-svc.yaml"
OK "OpenMetadata ingress configured"

# ── 10. Deploy demo UI ────────────────────────────────────────────────────────
Log "Deploying demo UI..."
kubectl apply -f "$root\demo-ui\k8s.yaml"
WaitForPods "default" "app=demo-ui"
OK "Demo UI running"

# ── 11. Run policy tests ──────────────────────────────────────────────────────
Log "Running policy unit tests..."
opa test "$root\policies" "$root\tests" -v
OK "All tests passed"

# ── 12. Summary ───────────────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Stack is ready!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Start port-forwards (run each in a separate terminal):" -ForegroundColor Yellow
Write-Host "  kubectl port-forward svc/opa 8181:8181"
Write-Host "  kubectl port-forward svc/mock-catalog 8080:8000"
Write-Host "  kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80"
Write-Host "  kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000"
Write-Host "  kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata"
Write-Host ""
Write-Host "Then open:" -ForegroundColor Yellow
Write-Host "  Demo UI:        http://localhost:8090/demo"
Write-Host "  OpenMetadata:   http://localhost:8585"
Write-Host "  OPA API:        http://localhost:8181/v1/data"
Write-Host ""
Write-Host "OpenMetadata login: admin@open-metadata.org / admin" -ForegroundColor Yellow