#!/usr/bin/env bash
# Host kernel/firewall/disk tuning required for a healthy kind cluster on Fedora.
# Each of these was a real failure mode when building this environment.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

# 1) firewalld: its reloads flush the iptables/nft FORWARD rules Docker installs
#    for the kind bridge, silently breaking cross-node pod networking.
if [[ "${DISABLE_FIREWALLD}" == "true" ]]; then
  if systemctl is-active --quiet firewalld; then
    log "Disabling firewalld (conflicts with kind bridge forwarding)"
    sudo systemctl disable --now firewalld
    sudo systemctl restart docker   # rebuild clean iptables integration
    ok "firewalld disabled, docker networking rebuilt"
  else ok "firewalld already inactive"; fi
fi

# 2) sysctls: inotify default (128) is too low for many pods -> 'too many open
#    files' crashloops; rp_filter must be 0 for forwarded pod traffic.
log "Applying sysctls (inotify limits, rp_filter, file-max)"
sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'CONF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
fs.file-max = 2097152
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
CONF
sudo sysctl --system >/dev/null
ok "sysctls applied and persisted"

# 3) disk: default Fedora cloud images ship a small root LV while the VG has free
#    extents. A full deploy needs ~25 GB. Extend if configured and possible.
if [[ "${EXTEND_ROOT_LV}" == "true" ]]; then
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if (( free_gb < MIN_ROOT_FREE_GB )); then
    lv=$(findmnt -no SOURCE /)
    if sudo vgs --noheadings -o vg_free 2>/dev/null | grep -qvE '^\s*0[gG]?\s*$'; then
      log "Root free ${free_gb}G < ${MIN_ROOT_FREE_GB}G — extending ${lv} into free VG space"
      sudo lvextend -r -l +100%FREE "$lv" && ok "root filesystem extended" || warn "lvextend failed (continuing)"
    else
      warn "Root free ${free_gb}G < ${MIN_ROOT_FREE_GB}G and no free VG extents — deploy may run out of disk"
    fi
  else ok "root free space ${free_gb}G is sufficient"; fi
fi
