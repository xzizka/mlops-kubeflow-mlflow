#!/usr/bin/env bash
# =============================================================================
#  MLOps Training Environment — one-command installer for Fedora 43+
#
#  Builds, from scratch and idempotently:
#    kind cluster (1 CP + 3 workers) -> Contour ingress -> MinIO -> MLflow
#    -> Kubeflow Pipelines + Training Operator -> JupyterLab + tutorial notebook
#
#  Usage:
#    cp .env.example .env      # then edit passwords/token
#    ./install.sh              # run all steps
#    ./install.sh 04 05        # run only specific steps (by number prefix)
#
#  Requirements: Fedora 43+, a sudo-capable user (NOPASSWD recommended),
#  internet access, ~25 GB free disk (auto-extended from the VG if configured).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
source lib/common.sh
load_env

STEPS=(
  00-prereqs
  01-host-tuning
  02-kind-cluster
  03-contour
  04-minio
  05-mlflow
  06-kubeflow
  07-trainer-image
  08-jupyter
  99-verify
)

run_step() {
  local s="$1"
  log "━━━ ${s} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bash "scripts/${s}.sh"
}

if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    match=""
    for s in "${STEPS[@]}"; do [[ "$s" == "$arg"* ]] && match="$s"; done
    [[ -n "$match" ]] || die "no step matching '$arg'"
    run_step "$match"
  done
else
  for s in "${STEPS[@]}"; do run_step "$s"; done
fi
