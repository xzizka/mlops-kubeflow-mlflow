#!/usr/bin/env bash
# Create the kind cluster: 1 control-plane + 3 workers, host ports 80/443 mapped.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster '${CLUSTER_NAME}' already exists"
else
  log "Creating kind cluster '${CLUSTER_NAME}' (1 control-plane + 3 workers)"
  render manifests/kind-config.yaml | kind create cluster --config - --wait 180s
  ok "cluster created"
fi

kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
log "Nodes:"
k get nodes -o wide
