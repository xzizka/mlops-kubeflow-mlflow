#!/usr/bin/env bash
# Build the trainer image and load it into the cluster so pipeline steps need no
# runtime pip (kind pods can't reach IPv6-only PyPI).
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

log "Building mlops-trainer:v1"
docker build -t mlops-trainer:v1 trainer/
log "Loading image into kind cluster '${CLUSTER_NAME}' (all nodes)"
kind load docker-image mlops-trainer:v1 --name "${CLUSTER_NAME}"
ok "mlops-trainer:v1 available in the cluster"
