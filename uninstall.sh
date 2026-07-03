#!/usr/bin/env bash
# Tear down the environment: stop JupyterLab and delete the kind cluster.
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh; load_env

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user disable --now jupyter.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/jupyter.service" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
ok "JupyterLab service stopped"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "cluster '${CLUSTER_NAME}' deleted"
else
  warn "cluster '${CLUSTER_NAME}' not found"
fi

warn "Kept: ~/mlops (venv, notebook, work), /etc/hosts entries, docker images."
warn "Remove manually if desired:  rm -rf ~/mlops"
