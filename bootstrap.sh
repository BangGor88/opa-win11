#!/usr/bin/env bash
# OPA stack bootstrap — macOS and Linux
# macOS lite mode: skips OpenMetadata when Docker memory < 12GB
# Usage: ./bootstrap.sh
# Run from repo root on a fresh machine after cloning

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "\n${CYAN}>> $1${NC}"; }
ok()   { echo -e "   ${GREEN}$1${NC}"; }
fail() { echo -e "   ${RED}ERROR: $1${NC}"; exit 1; }
warn() { echo -e "   ${YELLOW}WARNING: $1${NC}"; }

require() {
  if ! command -v "$1" &>/dev/null; then
    fail "$1 not found. See docs/setup-macos.md or docs/setup-linux.md."
  fi
  ok "$1 found"
}

wait_for_pods() {
  local ns="$1" label="$2" timeout="${3:-180}"
  log "Waiting for pods in '$ns' ($label)..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local ready
    ready=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null \
      | grep -E "Running" | grep -E "1/1|2/2" | wc -l | tr -d ' ')
    if [ "$ready" -gt 0 ]; then ok "Pods ready"; return 0; fi
    sleep 5; elapsed=$((elapsed + 5))
    printf "   ...waiting (%ds)\r" $elapsed
  done
  fail "Pods did not become ready in ${timeout}s. Run: kubectl get pods -n $ns"
}

# ── Detect available memory and set build profile ────────────────────────────
DOCKER_MEM_BYTES=$(docker system info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
DOCKER_MEM_GB=$(( DOCKER_MEM_BYTES / 1073741824 ))

if [ "$DOCKER_MEM_GB" -ge 12 ]; then
  PROFILE="full"
  MINIKUBE_MEMORY=12288
  ok "Detected ${DOCKER_MEM_GB}GB Docker memory — running full stack including OpenMetadata"
else
  PROFILE="lite"
  MINIKUBE_MEMORY=5120
  warn "Detected ${DOCKER_MEM_GB}GB Docker memory — running lite stack (OpenMetadata skipped)"
  warn "To run OpenMetadata, increase Docker Desktop memory to 12GB+"
fi

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
log "Checking prerequisites..."
require minikube
require kubectl
require helm
require docker
require opa

# ── 2. Minikube ──────────────────────────────────────────────────────────────
log "Starting Minikube (${MINIKUBE_MEMORY}MB RAM)..."
if minikube status --format="{{.Host}}" 2>/dev/null | grep -q "Running"; then
  ok "Minikube already running"
else
  minikube start --cpus 4 --memory "$MINIKUBE_MEMORY" --driver docker
  ok "Minikube started"
fi

minikube addons enable ingress     2>/dev/null || true
minikube addons enable ingress-dns 2>/dev/null || true

if [ "$PROFILE" = "full" ]; then
  minikube ssh "sudo sysctl -w vm.max_map_count=262144" 2>/dev/null || \
    warn "Could not set vm.max_map_count — OpenSearch may be unstable"
fi
ok "Minikube configured"

# ── 3. Docker env ────────────────────────────────────────────────────────────
log "Pointing Docker at Minikube..."
eval "$(minikube docker-env)"
ok "Docker env set"

# ── 4. Build images ──────────────────────────────────────────────────────────
log "Building mock-catalog image..."
docker build -t mock-catalog:latest "$ROOT/mock-app"
ok "mock-catalog built"

log "Building kafka-opa-app image..."
docker build -t kafka-opa-app:latest "$ROOT/kafka-app"
ok "kafka-opa-app built"

log "Building demo-ui image..."
docker build -t demo-ui:latest "$ROOT/demo-ui"
ok "demo-ui built"

# ── 5. Create namespaces and secrets ─────────────────────────────────────────
log "Creating namespaces..."
kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -

if [ "$PROFILE" = "full" ]; then
  kubectl create namespace openmetadata --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic mysql-secrets \
    --from-literal=openmetadata-mysql-password=openmetadata_password \
    -n openmetadata --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic airflow-secrets \
    --from-literal=openmetadata-airflow-password=openmetadata_password \
    -n openmetadata --dry-run=client -o yaml | kubectl apply -f -
fi
ok "Namespaces and secrets created"

# ── 6. Deploy OPA + mock app ─────────────────────────────────────────────────
log "Deploying OPA and mock catalog..."
kubectl apply -f "$ROOT/k8s/opa-configmap.yaml"
kubectl apply -f "$ROOT/k8s/opa.yaml"
kubectl apply -f "$ROOT/k8s/mock-app.yaml"
wait_for_pods "default" "app=opa"
wait_for_pods "default" "app=mock-catalog"
ok "OPA and mock catalog running"

# ── 7. Deploy Kong ───────────────────────────────────────────────────────────
log "Installing Kong..."
helm repo add kong https://charts.konghq.com 2>/dev/null || true
helm repo update 2>/dev/null

if helm list -n kong 2>/dev/null | grep -q "kong"; then
  ok "Kong already installed"
else
  helm install kong kong/ingress -n kong --create-namespace
fi
wait_for_pods "kong" "app.kubernetes.io/name=gateway"

log "Applying Kong OPA plugin..."
kubectl apply -f "$ROOT/kong/opa-plugin.yaml"
kubectl apply -f "$ROOT/kong/ingress.yaml"
kubectl set env deployment/kong-gateway -n kong KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson
wait_for_pods "kong" "app.kubernetes.io/name=gateway"
ok "Kong configured"

# ── 8. Deploy Kafka ───────────────────────────────────────────────────────────
log "Installing Strimzi operator..."
helm repo add strimzi https://strimzi.io/charts 2>/dev/null || true
helm repo update 2>/dev/null

if helm list -n kafka 2>/dev/null | grep -q "strimzi"; then
  ok "Strimzi already installed"
else
  helm install strimzi strimzi/strimzi-kafka-operator -n kafka --set watchNamespaces="{kafka}"
fi
wait_for_pods "kafka" "name=strimzi-cluster-operator"

log "Deploying Kafka cluster..."
kubectl apply -f "$ROOT/kafka/kafka-opa-configmap.yaml"
kubectl apply -f "$ROOT/kafka/kafka-cluster.yaml"
kubectl apply -f "$ROOT/kafka/kafka-app.yaml"
wait_for_pods "kafka" "app=kafka-opa-app" 300
ok "Kafka running"

# ── 9. Deploy OpenMetadata (full profile only) ────────────────────────────────
if [ "$PROFILE" = "full" ]; then
  log "Installing OpenMetadata dependencies..."
  helm repo add open-metadata https://helm.open-metadata.org 2>/dev/null || true
  helm repo update 2>/dev/null

  if helm list -n openmetadata 2>/dev/null | grep -q "openmetadata-dependencies"; then
    ok "OpenMetadata dependencies already installed"
  else
    helm install openmetadata-dependencies open-metadata/openmetadata-dependencies -n openmetadata
  fi
  wait_for_pods "openmetadata" "app=opensearch" 300
  wait_for_pods "openmetadata" "app=mysql" 180

  log "Installing OpenMetadata server..."
  if helm list -n openmetadata 2>/dev/null | grep -qE "^openmetadata\s"; then
    ok "OpenMetadata already installed"
  else
    helm install openmetadata open-metadata/openmetadata -n openmetadata
  fi
  wait_for_pods "openmetadata" "app=openmetadata" 300

  log "Applying OpenMetadata Kong ingress..."
  kubectl apply -f "$ROOT/openmetadata/kong-opa-plugin.yaml"
  kubectl apply -f "$ROOT/openmetadata/kong-ingress.yaml"
  kubectl apply -f "$ROOT/openmetadata/om-proxy-svc.yaml"
  ok "OpenMetadata running"
fi

# ── 10. Deploy demo UI ────────────────────────────────────────────────────────
log "Deploying demo UI..."
kubectl apply -f "$ROOT/demo-ui/k8s.yaml"
wait_for_pods "default" "app=demo-ui"
ok "Demo UI running"

# ── 11. Run policy tests ──────────────────────────────────────────────────────
log "Running policy unit tests..."
opa test "$ROOT/policies" "$ROOT/tests" -v
ok "All tests passed"

# ── 12. Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
if [ "$PROFILE" = "lite" ]; then
  echo -e "${GREEN}  Stack is ready! (lite — no OpenMetadata)${NC}"
else
  echo -e "${GREEN}  Stack is ready! (full)${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$PROFILE" = "lite" ]; then
  echo -e "${YELLOW}Lite build — OpenMetadata skipped (insufficient Docker memory).${NC}"
  echo -e "${YELLOW}Increase Docker Desktop memory to 12GB+ and re-run to get the full stack.${NC}"
  echo ""
fi

echo -e "${YELLOW}Start port-forwards (run each in a separate terminal):${NC}"
echo "  kubectl port-forward svc/opa 8181:8181"
echo "  kubectl port-forward svc/mock-catalog 8080:8000"
echo "  kubectl port-forward -n kong svc/kong-gateway-proxy 8090:80"
echo "  kubectl port-forward -n kafka svc/kafka-opa-app 8091:8000"
if [ "$PROFILE" = "full" ]; then
  echo "  kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata"
fi
echo ""
echo -e "${YELLOW}Then open:${NC}"
echo "  Demo UI:   http://localhost:8090/demo"
echo "  OPA API:   http://localhost:8181/v1/data"
if [ "$PROFILE" = "full" ]; then
  echo "  OpenMetadata: http://localhost:8585  (admin@open-metadata.org / admin)"
fi