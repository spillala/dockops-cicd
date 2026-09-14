#!/usr/bin/env bash
# Cluster-level bootstrap: addons, namespaces, Argo CD, and the dronefleet
# Application. Run after bootstrap-ubuntu.sh (which installs MicroK8s itself).
set -euo pipefail

KUBECTL="${KUBECTL:-microk8s kubectl}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
METALLB_RANGE="${METALLB_RANGE:-192.168.1.200-192.168.1.205}"

echo "Enabling MicroK8s addons..."
microk8s enable dns ingress "metallb:${METALLB_RANGE}" helm3 metrics-server

echo "Creating namespaces..."
$KUBECTL create namespace argocd --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL create namespace dronefleet --dry-run=client -o yaml | $KUBECTL apply -f -

echo "Installing Argo CD (${ARGOCD_VERSION})..."
$KUBECTL apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Waiting for Argo CD to be ready..."
$KUBECTL -n argocd rollout status deploy/argocd-server --timeout=180s

echo "Applying the dronefleet Argo CD Application..."
$KUBECTL apply -f argocd/dronefleet-app.yaml

cat <<EOF

Cluster bootstrap complete. Still needed before the first real deploy:

  1. GHCR image pull secret (see README.md > Deployed workload):
       GHCR_USERNAME=<you> GHCR_TOKEN=<PAT with read:packages> ./scripts/create-ghcr-pull-secret.sh dronefleet

  2. Postgres secret — dronefleet falls back to its in-memory store until
     this exists, and the bundled Postgres pod won't start without it:
       POSTGRES_PASSWORD=<pick one> ./scripts/create-postgres-secret.sh dronefleet

  3. GHCR image pull secret in the px4-sitl-gazebo namespace too — the
     mavlink-bridge sidecar pulls from GHCR just like dronefleet does:
       GHCR_USERNAME=<you> GHCR_TOKEN=<PAT with read:packages> ./scripts/create-ghcr-pull-secret.sh px4-sitl-gazebo

  4. Argo CD admin password, for UI/CLI login:
       $KUBECTL -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

  5. Calico CNI token refresh, as a cron job — the CNI plugin's kubeconfig
     token has a 24h TTL and calico-node's built-in refresher has a known
     upstream gap (projectcalico/calico#9235); without this, the cluster
     silently stops scheduling new pods once a day. See
     scripts/refresh-calico-cni-token.sh for why, and install it with:
       mkdir -p ~/logs
       ( echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"; \\
         crontab -l 2>/dev/null | grep -vF refresh-calico-cni-token.sh; \\
         echo "0 */6 * * * $(pwd)/scripts/refresh-calico-cni-token.sh >> ~/logs/calico-token-refresh.log 2>&1" \\
       ) | crontab -
EOF
