#!/usr/bin/env bash

set -euo pipefail

if ! command -v snap >/dev/null 2>&1; then
  echo "snap is required but not installed."
  exit 1
fi

echo "Installing MicroK8s and Helm..."
sudo snap install microk8s --classic
sudo snap install helm --classic

echo "Configuring user access..."
sudo usermod -a -G microk8s "$USER"
mkdir -p "$HOME/.kube"
sudo chown -R "$USER":"$USER" "$HOME/.kube"

echo
echo "Installation complete."
echo "Important: log out and log back in before using microk8s without sudo."
echo "Then run:"
echo "  newgrp microk8s"
echo "  microk8s status --wait-ready"
echo "  make bootstrap-local"

