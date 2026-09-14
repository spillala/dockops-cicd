#!/usr/bin/env bash
# Restarts calico-node to remint the CNI plugin's Kubernetes ServiceAccount
# token before it expires.
#
# Why this exists: /etc/cni/net.d/calico-kubeconfig carries a bound token
# for the calico-cni-plugin ServiceAccount with a 24h TTL. calico-node's
# built-in background refresher (CALICO_MANAGE_CNI) is subject to a known
# upstream timing gap that can leave it un-refreshed for hours past actual
# expiry (projectcalico/calico#9235) — in practice, on this single-node dev
# cluster, it did not refresh at all before hitting expiry. Once the token
# expires, every *new* pod's sandbox creation fails with:
#   plugin type="calico" failed (add): error getting ClusterInformation:
#   connection is unauthorized: Unauthorized
# Already-running pods are unaffected (CNI only runs at sandbox creation),
# but the cluster silently stops being able to schedule anything new until
# something restarts calico-node.
#
# Run on a schedule well inside the 24h TTL — see the crontab line below —
# rather than waiting to react to the failure.
set -euo pipefail

KUBECTL="${KUBECTL:-microk8s kubectl}"

$KUBECTL -n kube-system rollout restart daemonset/calico-node
$KUBECTL -n kube-system rollout status daemonset/calico-node --timeout=120s

echo "calico-node restarted, CNI token reminted."

# Installed as a cron job (every 6h — 4x inside the 24h token TTL, well past
# the worst-case refresh delay in the upstream bug above) — see `crontab -l`
# for the exact line; it logs to ~/logs/calico-token-refresh.log.
