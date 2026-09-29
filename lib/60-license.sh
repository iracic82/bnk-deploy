# Licence. Connected mode validates against F5 live, so a stale token fails here and not earlier.
: "${BNK_LICENSE_JWT:?BNK_LICENSE_JWT not set, or pass --skip-license}"
[[ "$DRY_RUN" == "1" ]] && { warn "dry run, skipping licence"; return 0; }

kubectl get crd licenses.k8s.f5net.com >/dev/null 2>&1 \
  || die "License CRD absent. The CNEInstance must finish installing CRDs first."

kubectl apply -n "$NS_CORE" -f - <<YAML >/dev/null
apiVersion: k8s.f5net.com/v1
kind: License
metadata:
  name: f5-cne-cluster-license
spec:
  operationMode: "${BNK_LICENSE_MODE:-connected}"
  jwt: "${BNK_LICENSE_JWT}"
YAML
ok "License applied in ${BNK_LICENSE_MODE:-connected} mode"

state=""
for i in $(seq 1 40); do
  state=$(kubectl get license.k8s.f5net.com f5-cne-cluster-license -n "$NS_CORE" \
            -o jsonpath='{.status.state}' 2>/dev/null || true)
  [[ "$state" == "Active" ]] && break
  sleep 10
done
if [[ "$state" == "Active" ]]; then
  ok "licence Active"
else
  warn "licence state is '${state:-unknown}' after 400s"
  warn "connected mode validates live against F5. Check the token is current and egress is open."
  kubectl describe license.k8s.f5net.com f5-cne-cluster-license -n "$NS_CORE" 2>/dev/null \
    | sed -n '/Events/,$p' | head -12
fi
