#!/usr/bin/env bash
set -euo pipefail

: "${GHCR_USERNAME:?Set GHCR_USERNAME to your GitHub username}"
: "${GHCR_TOKEN:?Set GHCR_TOKEN to a classic PAT with the read:packages scope}"

NAMESPACE="${1:-dronefleet}"
KUBECTL="${KUBECTL:-microk8s kubectl}"

$KUBECTL create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GHCR_TOKEN" \
  --docker-email="${GHCR_EMAIL:-noreply@example.com}" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "ghcr-pull-secret updated in namespace $NAMESPACE"
