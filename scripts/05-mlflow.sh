#!/usr/bin/env bash
# Deploy the MLflow tracking server (sqlite backend, artifacts in MinIO).
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

log "Deploying MLflow (pip install at first start — allow ~2 min)"
render manifests/mlflow.yaml | k apply -f - >/dev/null
wait_rollout mlflow mlflow 240s
ok "MLflow tracking server ready at http://mlflow.local"
