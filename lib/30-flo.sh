# F5 Lifecycle Operator. Everything else is reconciled by this.
if helm status f5-lifecycle-operator -n "$NS_CORE" >/dev/null 2>&1; then
  cur=$(helm get metadata f5-lifecycle-operator -n "$NS_CORE" -o json 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  ok "FLO already installed (${cur:-unknown})"
else
  [[ "$DRY_RUN" == "1" ]] && { warn "dry run, skipping helm install"; return 0; }
  helm install f5-lifecycle-operator "oci://${CNE_REPO}/charts/f5-lifecycle-operator" \
    --version "$FLO_VERSION" --namespace "$NS_CORE" \
    --set global.imagePullSecrets[0].name=far-pull-secret \
    --set image.repository="${CNE_REPO}/images" \
    --set containerPlatform=Generic \
    --set global.certmgr.clusterIssuer="$CLUSTER_ISSUER" >/dev/null
  ok "FLO ${FLO_VERSION} installed"
fi

[[ "$DRY_RUN" == "1" ]] && return 0
# FLO crash loops if the Multus CRD appeared after it started, so restart if it is unhealthy.
for i in $(seq 1 30); do
  phase=$(kubectl get pods -n "$NS_CORE" -l app.kubernetes.io/name=f5-lifecycle-operator \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Running" ]] && break
  sleep 10
done
restarts=$(kubectl get pods -n "$NS_CORE" -l app.kubernetes.io/name=f5-lifecycle-operator \
             -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
if [[ "${restarts:-0}" -gt 2 ]]; then
  warn "FLO restarted ${restarts} times, bouncing it so it re-discovers CRDs"
  kubectl rollout restart deploy/f5-lifecycle-operator -n "$NS_CORE" >/dev/null
  kubectl rollout status deploy/f5-lifecycle-operator -n "$NS_CORE" --timeout=180s >/dev/null
fi
crds=$(kubectl get crd -o name | grep -c 'k8s.f5.com' || true)
ok "FLO running, ${crds} F5 CRDs registered"
