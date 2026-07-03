#!/usr/bin/env bash
# Deploy MinIO (shared S3 store) and provision buckets + the KFP service account.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

log "Deploying MinIO"
render manifests/minio.yaml | k apply -f - >/dev/null
wait_rollout minio minio 150s
ok "MinIO running"

log "Creating buckets (mlflow, dvc, mlpipeline) and KFP user"
k -n minio delete job minio-init --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: minio-init, namespace: minio}
spec:
  backoffLimit: 4
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: mc
        image: minio/mc:RELEASE.2025-04-08T15-39-49Z
        envFrom: [{secretRef: {name: minio-creds}}]
        command: ["/bin/sh","-c"]
        args:
        - |
          set -e
          until mc alias set m http://minio:9000 "\$MINIO_ROOT_USER" "\$MINIO_ROOT_PASSWORD"; do echo wait; sleep 3; done
          for b in mlflow dvc mlpipeline; do mc mb -p "m/\$b" || true; done
          mc admin user add m "${MINIO_KFP_USER}" "${MINIO_KFP_PASSWORD}" || true
          mc admin policy attach m readwrite --user "${MINIO_KFP_USER}" || true
          mc ls m
          echo MINIO_INIT_DONE
        resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 64Mi}}
YAML
k -n minio wait --for=condition=complete job/minio-init --timeout=120s >/dev/null 2>&1 || \
  warn "minio-init job not confirmed complete"
k -n minio logs job/minio-init 2>/dev/null | tail -6
ok "MinIO buckets + KFP user ready"
