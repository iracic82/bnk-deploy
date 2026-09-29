# Verification. Every assertion here replaces an "Expect:" line from the install guide.
fails=0
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "FAIL $1"; fails=$((fails+1)); fi; }

chk "FLO running"            "kubectl get pods -n $NS_CORE -l app.kubernetes.io/name=f5-lifecycle-operator -o jsonpath='{.items[0].status.phase}' | grep -q Running"
chk "F5 CRDs registered"     "[ \$(kubectl get crd -o name | grep -c 'k8s.f5') -gt 20 ]"
chk "CNEInstance exists"     "kubectl get cneinstance -n $NS_BNK f5-bnk-instance"
chk "no pods crash looping"  "! kubectl get pods -n $NS_BNK --no-headers | grep -q CrashLoopBackOff"
chk "no image pull errors"   "! kubectl get pods -A --no-headers | grep -qE 'ImagePullBackOff|ErrImagePull'"
chk "Gateway API present"    "kubectl get crd gatewayclasses.gateway.networking.k8s.io"
if [[ "$SKIP_LICENSE" == "0" ]]; then
  chk "licence Active"       "kubectl get license.k8s.f5net.com f5-cne-cluster-license -n $NS_CORE -o jsonpath='{.status.state}' | grep -q Active"
fi
avail=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
tmm=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance \
        -o jsonpath='{.status.conditions[?(@.type=="F5TmmAvailable")].status}' 2>/dev/null || true)

# An unlicensed install cannot bring up TMM, and that is by design rather than a fault.
# f5-cne-controller logs "License is not enabled.. skip Resource controllers" and never creates
# the TMM workload. So do not report it as a problem when the licence was deliberately skipped.
if [[ "$avail" == "True" ]]; then
  ok "CNEInstance Available"
elif [[ "$SKIP_LICENSE" == "1" && "$tmm" != "True" ]]; then
  ok "control plane up. TMM absent, expected: unlicensed installs skip the resource controllers"
  others=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance \
             -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null \
             | tr ' ' '\n' | grep '=False$' | grep -vE '^(Available|F5TmmAvailable)=' | sed 's/=False//' | paste -sd, - || true)
  [[ -n "$others" ]] && { warn "but these are also not ready: $others"; fails=$((fails+1)); }
else
  warn "CNEInstance Available=${avail:-unset}, F5TmmAvailable=${tmm:-unset}"
  fails=$((fails+1))
fi

echo
echo "    pods: $(kubectl get pods -n $NS_CORE --no-headers 2>/dev/null | grep -c Running) running in $NS_CORE, $(kubectl get pods -n $NS_BNK --no-headers 2>/dev/null | grep -c Running) in $NS_BNK"
[[ "$fails" -gt 0 ]] && die "$fails verification check(s) failed"
ok "all checks passed"
