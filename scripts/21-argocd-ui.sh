#!/usr/bin/env bash
# Open the Argo CD UI at http://localhost:8085 (keeps running – Ctrl+C to stop).
# Restarts the port-forward automatically if it drops (pod restart, Mac sleep).
set -uo pipefail
kubectl config use-context kind-kc-lab >/dev/null
echo "Argo CD UI: http://localhost:8085   (Ctrl+C to stop)"
while true; do
  kubectl -n argocd port-forward svc/argocd-server 8085:80
  echo "port-forward stopped – restarting in 2s..."; sleep 2
done
