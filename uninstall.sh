#!/usr/bin/env bash
# Remove BNK. Leaves cert-manager, Multus and Calico alone since other things may use them.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/versions.env"
kubectl delete cneinstance -n "$NS_BNK" f5-bnk-instance --ignore-not-found --timeout=300s
kubectl delete license.k8s.f5net.com -n "$NS_CORE" f5-cne-cluster-license --ignore-not-found
helm uninstall f5-lifecycle-operator -n "$NS_CORE" 2>/dev/null || true
kubectl delete ns "$NS_BNK" "$NS_CORE" --ignore-not-found --timeout=300s
kubectl get crd -o name | grep -E 'k8s.f5(net)?.com' | xargs -r kubectl delete --ignore-not-found
echo "BNK removed. cert-manager, Multus and Calico were left in place."
