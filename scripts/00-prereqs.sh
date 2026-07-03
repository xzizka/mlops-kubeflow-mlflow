#!/usr/bin/env bash
# Install Docker, kind, kubectl, helm, kustomize and supporting tools.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

ARCH=amd64
KIND_VERSION=v0.30.0

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker CE + tools via dnf"
  sudo tee /etc/yum.repos.d/docker-ce.repo >/dev/null <<'REPO'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
REPO
  sudo dnf -y --setopt=retries=10 install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "docker installed"
else ok "docker present"; fi

# Supporting tools (gettext provides envsubst; python3.12 for the Jupyter venv)
sudo dnf -y install git python3-pip tar gettext jq python3.12 >/dev/null
ok "git / pip / envsubst / python3.12 present"

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

install_bin() { # url dest
  sudo curl -fsSL -o "$2" "$1"; sudo chmod +x "$2"; }

command -v kubectl >/dev/null 2>&1 || {
  log "Installing kubectl"
  KV=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  install_bin "https://dl.k8s.io/release/${KV}/bin/linux/${ARCH}/kubectl" /usr/local/bin/kubectl; }
command -v kind >/dev/null 2>&1 || {
  log "Installing kind ${KIND_VERSION}"
  install_bin "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" /usr/local/bin/kind; }
command -v helm >/dev/null 2>&1 || {
  log "Installing helm"; curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash; }
command -v kustomize >/dev/null 2>&1 || {
  log "Installing kustomize"
  (cd /tmp && curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash && sudo mv kustomize /usr/local/bin/); }

ok "kubectl / kind / helm / kustomize present"

# kind needs Docker access without sudo. If the docker group isn't active in this
# shell yet, stop and ask the user to re-run in a fresh login shell.
if ! docker info >/dev/null 2>&1; then
  warn "Docker group not active in this shell."
  warn "Log out and back in (or run 'newgrp docker'), then re-run ./install.sh"
  exit 1
fi
ok "docker usable without sudo"
