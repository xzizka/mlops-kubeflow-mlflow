#!/usr/bin/env bash
# Verify the environment and print access URLs + the Jupyter token.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env
IP=$(host_ip); : "${IP:=<host-ip>}"

echo
log "Cluster nodes"
k get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion --no-headers

log "Core workloads"
for ns in projectcontour minio mlflow kubeflow; do
  tot=$(k -n "$ns" get deploy --no-headers 2>/dev/null | wc -l)
  rdy=$(k -n "$ns" get deploy -o json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for x in d["items"] if (x.get("status",{}).get("readyReplicas",0))==(x["spec"]["replicas"])))' 2>/dev/null || echo "?")
  echo "  ${ns}: ${rdy}/${tot} deployments ready"
done

echo
log "External endpoint checks (Host-routed via Contour)"
ep() { printf "  %-22s " "$1"; curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 12 -H "Host: $2" "http://${IP}/$3" 2>/dev/null || echo "unreachable"; }
ep "Kubeflow API"   kubeflow.local apis/v2beta1/healthz
ep "MLflow"         mlflow.local   health
ep "MinIO S3"       s3.local       minio/health/ready
printf "  %-22s " "JupyterLab :${JUPYTER_PORT}"; curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 12 "http://${IP}:${JUPYTER_PORT}/lab?token=${JUPYTER_TOKEN}" 2>/dev/null || echo "unreachable"

cat <<EOF

╔══════════════════════════════════════════════════════════════════════════╗
  ✅  MLOps training environment ready
╚══════════════════════════════════════════════════════════════════════════╝

  JupyterLab (no setup):
    http://${IP}:${JUPYTER_PORT}/lab?token=${JUPYTER_TOKEN}
    → MLOps_Tutorial.ipynb is pre-loaded.

  Web UIs — add to your client's /etc/hosts:
    ${IP}  kubeflow.local mlflow.local minio.local s3.local
  then browse:
    Kubeflow Pipelines : http://kubeflow.local
    MLflow             : http://mlflow.local
    MinIO console      : http://minio.local   (${MINIO_ROOT_USER} / ****)

  Jupyter token : ${JUPYTER_TOKEN}
  MinIO root    : ${MINIO_ROOT_USER} / (see .env)
EOF
