#!/usr/bin/env bash
set -euo pipefail

: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD to the password for the dronefleet Postgres user}"

NAMESPACE="${1:-dronefleet}"
KUBECTL="${KUBECTL:-microk8s kubectl}"
DB_USER="${POSTGRES_USER:-dronefleet}"
DB_NAME="${POSTGRES_DB:-dronefleet}"
DB_SVC="${POSTGRES_SVC:-dronefleet-postgres-svc}"

DATABASE_URL="postgres://${DB_USER}:${POSTGRES_PASSWORD}@${DB_SVC}:5432/${DB_NAME}?sslmode=disable"

$KUBECTL create secret generic dronefleet-postgres-secret \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=database-url="$DATABASE_URL" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "dronefleet-postgres-secret updated in namespace $NAMESPACE"
