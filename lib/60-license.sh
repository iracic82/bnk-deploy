# Licence. Connected mode validates against F5 live, so a stale token fails here and not earlier.
: "${BNK_LICENSE_JWT:?BNK_LICENSE_JWT not set, or pass --skip-license}"
[[ "$DRY_RUN" == "1" ]] && { warn "dry run, skipping licence"; return 0; }

kubectl get crd licenses.k8s.f5net.com >/dev/null 2>&1 \
  || die "License CRD absent. The CNEInstance must finish installing CRDs first."

# BNK creates a ResourceQuota named f5-single-license-quota, and Kubernetes refuses a create against
# a quota whose status the controller has not yet computed:
#   licenses.k8s.f5net.com "f5-cne-cluster-license" is forbidden:
#   status unknown for quota: f5-single-license-quota
# That is a race, not a licence problem, and a single attempt fails perhaps one install in ten.
# Retry only that specific error; surface anything else immediately. (Proven in the Instruqt lab's
# setup-bnk; the installer is the authoritative place, so it belongs here.)
lic_err=""
for attempt in $(seq 1 12); do
  lic_err=$(kubectl apply -n "$NS_CORE" -f - <<YAML 2>&1 >/dev/null
apiVersion: k8s.f5net.com/v1
kind: License
metadata:
  name: f5-cne-cluster-license
spec:
  operationMode: "${BNK_LICENSE_MODE:-connected}"
  jwt: "${BNK_LICENSE_JWT}"
YAML
  ) && { lic_err=""; break; }
  case "$lic_err" in
    *"status unknown for quota"*)
      warn "license quota not ready yet, retrying (${attempt}/12)"
      sleep 10 ;;
    *) break ;;
  esac
done
[[ -z "$lic_err" ]] || die "could not apply the License resource: ${lic_err}"
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
