#!/usr/bin/env bash
# Runs on the jumphost after the cluster-up phase. Puts a usable kubeconfig on the host and
# pulls a copy back to the jumphost so later phases and CI can talk to the cluster.
set -euo pipefail
source "${SITE_ENV:?SITE_ENV must point at env/<site>.env}"
POC_DIR="${POC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
host() { ssh -o StrictHostKeyChecking=no "${HOST_USER}@${HOST_ADDR}" "$@"; }

host bash -s <<REMOTE
set -euo pipefail
mkdir -p \$HOME/.kube
sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown "${HOST_USER}:${HOST_USER}" \$HOME/.kube/config
chmod 600 \$HOME/.kube/config
kubectl get nodes
REMOTE

mkdir -p "${POC_DIR}/artifacts"
host sudo cat /etc/kubernetes/admin.conf > "${POC_DIR}/artifacts/kubeconfig"
chmod 600 "${POC_DIR}/artifacts/kubeconfig"
echo "kubeconfig staged at ${POC_DIR}/artifacts/kubeconfig"
echo "cluster-up post-script done"
