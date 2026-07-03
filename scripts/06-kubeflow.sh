#!/usr/bin/env bash
# Install Kubeflow Pipelines + Training Operator, then repoint the artifact
# store from the bundled (broken) seaweedfs to the shared MinIO.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

log "Installing Kubeflow Pipelines ${KFP_VERSION} (cluster-scoped resources)"
k apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${KFP_VERSION}" >/dev/null
k wait --for condition=established --timeout=60s crd/applications.app.k8s.io >/dev/null 2>&1 || true

log "Installing Kubeflow Pipelines (platform-agnostic workloads)"
k apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=${KFP_VERSION}" >/dev/null

log "Installing Training Operator ${TRAINING_OPERATOR_REF}"
k apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=${TRAINING_OPERATOR_REF}" >/dev/null

log "Waiting for the KFP API server to appear"
k -n kubeflow rollout status deploy/ml-pipeline --timeout=300s >/dev/null 2>&1 || \
  warn "ml-pipeline not confirmed yet (continuing to repoint)"

# ── Repoint KFP artifact store to MinIO ──────────────────────────────────────
log "Repointing KFP object store to MinIO (bucket mlpipeline)"

# 1) credentials KFP uses (must match the MinIO user created in step 04)
k -n kubeflow create secret generic mlpipeline-minio-artifact \
  --from-literal=accesskey="${MINIO_KFP_USER}" \
  --from-literal=secretkey="${MINIO_KFP_PASSWORD}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null

# 2) API server object-store endpoint
k -n kubeflow set env deploy/ml-pipeline \
  OBJECTSTORECONFIG_HOST=minio.minio.svc.cluster.local \
  OBJECTSTORECONFIG_PORT=9000 >/dev/null

# 3) KFP v2 launcher provider config (per-step artifact I/O)
k apply -f manifests/kfp-launcher.yaml >/dev/null

# 4) Argo workflow-controller artifact repository (step logs)
ar=$(k -n kubeflow get cm workflow-controller-configmap -o jsonpath='{.data.artifactRepository}')
ar=${ar//seaweedfs.kubeflow:9000/minio.minio.svc.cluster.local:9000}
k -n kubeflow patch cm workflow-controller-configmap --type merge \
  -p "$(ar="$ar" python3 -c 'import json,os; print(json.dumps({"data":{"artifactRepository":os.environ["ar"]}}))')" >/dev/null

# 5) restart everything that reads the object-store config
k -n kubeflow rollout restart deploy/ml-pipeline deploy/workflow-controller \
  deploy/metadata-writer deploy/cache-server deploy/ml-pipeline-persistenceagent >/dev/null

# 6) expose the Pipelines UI via ingress
k apply -f manifests/kfp-ingress.yaml >/dev/null

log "Waiting for KFP API server to become ready with MinIO config"
wait_rollout kubeflow ml-pipeline 200s
ok "Kubeflow Pipelines + Training Operator ready; artifact store = MinIO"
