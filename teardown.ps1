# OPA stack teardown — Windows
# Usage: .\teardown.ps1
# Run from repo root

$ErrorActionPreference = "SilentlyContinue"

function Log($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function OK($msg)  { Write-Host "   $msg" -ForegroundColor Red }

Log "Removing Kubernetes manifests..."
kubectl delete -f k8s/          --ignore-not-found 2>$null
kubectl delete -f kong/         --ignore-not-found 2>$null
kubectl delete -f kafka/        --ignore-not-found 2>$null
kubectl delete -f demo-ui/      --ignore-not-found 2>$null
kubectl delete -f openmetadata/ --ignore-not-found 2>$null
OK "Manifests removed"

Log "Uninstalling Helm releases..."
helm uninstall kong                      -n kong         2>$null
helm uninstall strimzi                   -n kafka        2>$null
helm uninstall openmetadata              -n openmetadata 2>$null
helm uninstall openmetadata-dependencies -n openmetadata 2>$null
OK "Helm releases removed"

Log "Deleting namespaces..."
kubectl delete namespace kong         --ignore-not-found 2>$null
kubectl delete namespace kafka        --ignore-not-found 2>$null
kubectl delete namespace openmetadata --ignore-not-found 2>$null
OK "Namespaces deleted"

Log "Stopping Minikube..."
minikube stop
OK "Minikube stopped"

Write-Host "`nTeardown complete. Run .\bootstrap.ps1 to rebuild from scratch." -ForegroundColor Cyan