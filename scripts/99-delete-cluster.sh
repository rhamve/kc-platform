#!/usr/bin/env bash
# Delete the kind cluster (everything inside it is lost)
set -euo pipefail
kind delete cluster --name kc-lab
