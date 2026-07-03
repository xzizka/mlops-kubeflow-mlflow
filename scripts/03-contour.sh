#!/usr/bin/env bash
# Deploy Contour (Envoy) ingress, pinned to the ingress-ready control-plane node.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh; load_env

log "Applying Contour quickstart"
k apply -f https://projectcontour.io/quickstart/contour.yaml >/dev/null

log "Pinning Envoy to the control-plane node (has the 80/443 host mapping)"
k -n projectcontour patch daemonset envoy --type strategic -p '
spec:
  template:
    spec:
      nodeSelector:
        ingress-ready: "true"
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
' >/dev/null

k apply -f manifests/ingressclass.yaml >/dev/null

log "Waiting for Contour + Envoy (Envoy image pull can take a couple of minutes)"
wait_rollout projectcontour contour 180s
k -n projectcontour rollout status daemonset/envoy --timeout=240s >/dev/null 2>&1 || \
  warn "envoy rollout not confirmed (continuing)"
ok "Contour ingress ready on host ports 80/443"
