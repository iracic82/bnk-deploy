#!/usr/bin/env bash
# Remove BNK. By default leaves cert-manager, Multus and Calico alone, since other things may use them.
# --full also removes the cert-manager artifacts BNK itself created (the CA chain and its two
# ClusterIssuers), for a clean teardown on a cluster where BNK was the only cert-manager consumer.
#
# Tolerant of a half-installed cluster: a partial or failed install may have no BNK CRDs at all, and
# `kubectl delete cneinstance` then errors with "doesn't have a resource type" (which --ignore-not-found
# does not catch) and, under set -e, would abort the whole teardown. So the CR deletes are guarded on
# the CRD being present, and every step is non-fatal, so --full cleanup always runs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/versions.env"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

if kubectl get crd 2>/dev/null | grep -q cneinstance; then
  kubectl delete cneinstance -n "$NS_BNK" f5-bnk-instance --ignore-not-found --timeout=300s || true
fi
if kubectl get crd licenses.k8s.f5net.com >/dev/null 2>&1; then
  kubectl delete license.k8s.f5net.com -n "$NS_CORE" f5-cne-cluster-license --ignore-not-found || true
fi
helm uninstall f5-lifecycle-operator -n "$NS_CORE" 2>/dev/null || true
kubectl delete ns "$NS_BNK" "$NS_CORE" --ignore-not-found --timeout=300s || true
crds="$(kubectl get crd -o name 2>/dev/null | grep -E 'k8s.f5(net)?.com' || true)"
[[ -n "$crds" ]] && printf '%s\n' "$crds" | xargs -r kubectl delete --ignore-not-found || true

if [[ "$FULL" == "1" ]]; then
  # The CA chain BNK created in cert-manager: two cluster-scoped issuers and the CA cert + secret.
  kubectl delete clusterissuer "${CLUSTER_ISSUER}" temp-selfsigned --ignore-not-found || true
  kubectl delete certificate f5-cne-ca -n cert-manager --ignore-not-found || true
  kubectl delete secret f5-cne-ca-secret -n cert-manager --ignore-not-found || true
  echo "BNK removed, including the cert-manager CA chain it created. cert-manager, Multus and Calico remain."
else
  echo "BNK removed. cert-manager, Multus and Calico were left in place (use --full to also remove BNK's CA chain)."
fi
