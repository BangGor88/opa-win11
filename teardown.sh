#!/usr/bin/env bash
# OPA stack teardown — macOS and Linux
# Usage: ./teardown.sh

set -euo pipefail

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "\n${CYAN}>> $1${NC}"; }
ok()   { echo -e "   ${RED}$1${NC}"; }

log "Removing Kubernetes manifests..."
kubectl delete -f k8s/      --ignore-not-found 2>/dev/null || true
kubectl delete -f kong/     --ignore-not-found 2>/dev/null || true
kubectl delete -f kafka/    --ignore-not-found 2>/dev/null || true
kubectl delete -f demo-ui/  --ignore-not-found 2>/dev/null || true
kubectl delete -f openmetadata/ --ignore-not-found 2>/dev/null || true
ok "Manifests removed"

log "Uninstalling Helm releases..."
helm uninstall kong                       -n kong          2>/dev/null || true
helm uninstall strimzi                    -n kafka         2>/dev/null || true
helm uninstall openmetadata               -n openmetadata  2>/dev/null || true
helm uninstall openmetadata-dependencies  -n openmetadata  2>/dev/null || true
ok "Helm releases removed"

log "Deleting namespaces..."
kubectl delete namespace kong          --ignore-not-found 2>/dev/null || true
kubectl delete namespace kafka         --ignore-not-found 2>/dev/null || true
kubectl delete namespace openmetadata  --ignore-not-found 2>/dev/null || true
ok "Namespaces deleted"

log "Stopping Minikube..."
minikube stop
ok "Minikube stopped"

echo ""
echo -e "${CYAN}Teardown complete. Run ./bootstrap.sh to rebuild from scratch.${NC}"