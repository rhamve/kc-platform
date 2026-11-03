#!/usr/bin/env bash
# Phase 0: create the kind cluster and check it is healthy
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool (brew install $tool)"; exit 1; }
done

if kind get clusters | grep -qx kc-lab; then
  echo "Cluster kc-lab already exists"
else
  kind create cluster --config kind/cluster.yaml
fi

kubectl config use-context kind-kc-lab
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -L topology.kubernetes.io/zone -o wide
