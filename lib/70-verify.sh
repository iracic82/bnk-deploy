# Verification. Every assertion here replaces an "Expect:" line from the install guide.
fails=0
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "FAIL $1"; fails=$((fails+1)); fi; }

chk "FLO running"            "flo=\$(kubectl get deploy f5-lifecycle-operator -n $NS_CORE -o jsonpath='{.status.readyReplicas}' 2>/dev/null); [ \"\${flo:-0}\" -ge 1 ]"
chk "F5 CRDs registered"     "[ \$(kubectl get crd -o name | grep -c 'k8s.f5') -gt 20 ]"
chk "CNEInstance exists"     "kubectl get cneinstance -n $NS_BNK f5-bnk-instance"
chk "no pods crash looping"  "! kubectl get pods -A --no-headers | grep -E '^($NS_BNK|$NS_CORE) ' | grep -q CrashLoopBackOff"
chk "no image pull errors"   "! kubectl get pods -A --no-headers | grep -qE 'ImagePullBackOff|ErrImagePull'"
# Installed by BNK's own CRD installer, so its absence means the install did not get far enough
# rather than that the cluster is missing something.
chk "Gateway API present"    "kubectl get crd gatewayclasses.gateway.networking.k8s.io"
chk "control plane has pods" "[ \$(kubectl get pods -n $NS_CORE --no-headers 2>/dev/null | grep -c Running) -ge 5 ]"
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
echo "    pods: $(kubectl get pods -n "$NS_CORE" --no-headers 2>/dev/null | grep -c Running) running in $NS_CORE, $(kubectl get pods -n "$NS_BNK" --no-headers 2>/dev/null | grep -c Running) in $NS_BNK"

# A count of failures is not a diagnosis. Anything that failed above leaves the cluster in a state
# worth printing, and this costs nothing on a healthy run because it only runs on failure. Without it
# a single FAIL line sends the next person back to the cluster to guess.
if [[ "$fails" -gt 0 ]]; then
  echo
  echo "    what the cluster looked like when these checks ran:"
  for ns in "$NS_CORE" "$NS_BNK"; do
    phases=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
               | awk '{c[$3]++} END {for (p in c) printf "%s=%s ", p, c[p]}')
    echo "      $ns: ${phases:-no pods}"
  done
  # Deployments and StatefulSets carry spec.replicas and status.readyReplicas. DaemonSets carry
  # neither, so asking for them returns <none> and every DaemonSet reads as 0/1 short. That false
  # line is exactly the kind of thing this block exists to prevent, so DaemonSets are queried with
  # their own fields.
  short=$(kubectl get deploy,sts -n "$NS_CORE" \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,WANT:.spec.replicas,READY:.status.readyReplicas' \
    --no-headers 2>/dev/null \
    | awk '{r=($4=="<none>"?0:$4); if (r!=$3) printf "        %s/%s %s/%s ready\n", $1, $2, r, $3}')
  short="$short$(kubectl get ds -n "$NS_CORE" \
    -o 'custom-columns=NAME:.metadata.name,WANT:.status.desiredNumberScheduled,READY:.status.numberReady' \
    --no-headers 2>/dev/null \
    | awk '{r=($3=="<none>"?0:$3); w=($2=="<none>"?0:$2); if (r!=w) printf "        DaemonSet/%s %s/%s ready\n", $1, r, w}')"
  [[ -n "$short" ]] && { echo "      workloads short of their replicas:"; echo "$short"; }
  restarts=$(kubectl get pods -n "$NS_CORE" \
    -o 'custom-columns=N:.metadata.name,R:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null \
    | awk '$2 ~ /[1-9]/ {printf "        %s restarts=%s\n", $1, $2}')
  [[ -n "$restarts" ]] && { echo "      pods that have restarted:"; echo "$restarts"; }
  why=$(kubectl get pods -n "$NS_CORE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.lastState.terminated.reason}{" "}{end}{"\n"}{end}' 2>/dev/null \
    | awk 'NF>1 {printf "        %s\n", $0}')
  [[ -n "$why" ]] && { echo "      last termination reasons, OOMKilled here would explain a lot:"; echo "$why"; }
  echo "      recent warnings:"
  kubectl get events -n "$NS_CORE" --field-selector type=Warning \
    -o 'custom-columns=OBJ:.involvedObject.name,REASON:.reason,MSG:.message' --no-headers 2>/dev/null \
    | tail -8 | sed 's/^/        /' || true
fi
[[ "$fails" -gt 0 ]] && die "$fails verification check(s) failed"
ok "all checks passed"
