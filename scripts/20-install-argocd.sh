#!/usr/bin/env bash
# Phase 2a: install Argo CD into the kind cluster with Helm (the one manual bootstrap step –
# Argo CD can't deploy itself before it exists; from 2b on, everything else comes from Git).
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.8.3}"   # check newer: helm search repo argo/argo-cd --versions | head

kubectl config use-context kind-kc-lab
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f argocd/install/values.yaml \
  --wait --timeout 10m

kubectl -n argocd get pods
echo
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo
echo "Open the UI:  kubectl -n argocd port-forward svc/argocd-server 8085:80"
echo "Then browse:  http://localhost:8085   (user: admin)"
