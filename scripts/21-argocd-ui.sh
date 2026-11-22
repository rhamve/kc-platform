#!/usr/bin/env bash
# Open the Argo CD UI at http://localhost:8085 (keeps running – Ctrl+C to stop).
# Restarts the port-forward automatically if it drops (pod restart, Mac sleep).
set -uo pipefail
PORT=8085
kubectl config use-context kind-kc-lab >/dev/null

# Something already listening on the port? (usually an earlier port-forward still running)
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use by:"
  lsof -nP -iTCP:$PORT -sTCP:LISTEN
  echo
  echo "Process state (T = suspended by Ctrl+Z – holds the port but answers nothing):"
  ps -o pid,stat,command -p "$(lsof -t -iTCP:$PORT -sTCP:LISTEN | head -1)"
  echo
  echo "If curl -sI http://127.0.0.1:$PORT answers, the UI already works: http://localhost:$PORT"
  echo "Otherwise stop it and start fresh:  kill -9 \$(lsof -t -iTCP:$PORT -sTCP:LISTEN) && $0"
  exit 1
fi

echo "Argo CD UI: http://localhost:$PORT   (Ctrl+C to stop)"
trap 'echo; echo "Stopped."; exit 0' INT
while true; do
  kubectl -n argocd port-forward svc/argocd-server $PORT:80
  echo "port-forward stopped – restarting in 2s... (Ctrl+C to quit – never Ctrl+Z, it only pauses)"; sleep 2
done
