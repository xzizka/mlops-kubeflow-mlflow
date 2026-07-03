#!/usr/bin/env bash
# Set up JupyterLab on the host: venv, MLOps client libs, tutorial notebook,
# /etc/hosts ingress names, and a lingering user systemd service.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

MLROOT="$HOME/mlops"
VENV="$MLROOT/venv"
mkdir -p "$MLROOT/work"

if [[ ! -x "$VENV/bin/python" ]]; then
  log "Creating Python 3.12 venv"
  python3.12 -m venv "$VENV"
fi
log "Installing MLOps client libraries (jupyterlab, mlflow, dvc, kfp, sklearn ...)"
"$VENV/bin/pip" install --quiet --upgrade pip wheel >/dev/null
"$VENV/bin/pip" install --quiet \
  jupyterlab notebook "mlflow==2.19.0" boto3 "dvc[s3]" "kfp==2.13.0" \
  scikit-learn pandas numpy matplotlib pyarrow
ok "client libraries installed"

# S3 path-style addressing so a single ingress hostname (s3.local) works with MinIO
mkdir -p "$HOME/.aws"
cat > "$HOME/.aws/config" <<'CFG'
[default]
region = us-east-1
s3 =
    addressing_style = path
CFG

# Runtime env for the notebook process (loaded by the systemd service)
cat > "$MLROOT/.env" <<ENV
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
ENV
chmod 600 "$MLROOT/.env"

log "Generating tutorial notebook"
MINIO_ROOT_USER="${MINIO_ROOT_USER}" MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  "$VENV/bin/python" notebook/gen_notebook.py "$MLROOT/MLOps_Tutorial.ipynb"

# Resolve ingress hostnames locally so the notebook client can reach the UIs/S3
if ! grep -q "kubeflow.local" /etc/hosts; then
  echo "127.0.0.1 mlflow.local kubeflow.local s3.local minio.local jupyter.local" | sudo tee -a /etc/hosts >/dev/null
fi
ok "/etc/hosts ingress names present"

log "Creating lingering user systemd service for JupyterLab"
sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/jupyter.service" <<UNIT
[Unit]
Description=JupyterLab MLOps Training
After=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/mlops
Environment=KUBECONFIG=%h/.kube/config
EnvironmentFile=%h/mlops/.env
ExecStart=%h/mlops/venv/bin/jupyter lab --ServerApp.ip=0.0.0.0 --ServerApp.port=${JUPYTER_PORT} --ServerApp.token=${JUPYTER_TOKEN} --ServerApp.allow_remote_access=True --ServerApp.allow_origin=* --ServerApp.root_dir=%h/mlops --ServerApp.open_browser=False
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now jupyter.service
ok "JupyterLab service started on port ${JUPYTER_PORT}"
