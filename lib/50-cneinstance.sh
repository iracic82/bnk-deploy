# CNEInstance. The whole data plane shape lives in this one object.
prof="$HERE/profiles/${PROFILE}.yaml"
[[ -r "$prof" ]] || die "no profile at $prof"

sc="${BNK_STORAGECLASS:-}"
[[ -n "$sc" ]] && kubectl get sc "$sc" >/dev/null 2>&1 || sc="$(kubectl get sc -o jsonpath='{.items[0].metadata.name}')"
# shellcheck disable=SC1091
source "$HERE/lib/render.sh"

sc="${BNK_STORAGECLASS:-}"
if [[ -z "$sc" ]] || ! kubectl get sc "$sc" >/dev/null 2>&1; then
  sc="$(kubectl get sc -o jsonpath='{.items[0].metadata.name}')"
fi
_render_sc="$sc"
rendered="$(render_cneinstance "$prof")"

if [[ "$DRY_RUN" == "1" ]]; then
  if echo "$rendered" | kubectl apply -n "$NS_BNK" --dry-run=server -f - >/dev/null; then
    ok "CNEInstance (${PROFILE}) validates server side"
  else
    die "CNEInstance rejected by the API server"
  fi
  return 0
fi
echo "$rendered" | kubectl apply -n "$NS_BNK" -f - >/dev/null
ok "CNEInstance applied, profile ${PROFILE}"
echo "    waiting for the operator to lay down the stack, this takes several minutes"

# Do NOT wait on "running pods == total pods". A StatefulSet that has not created its next replica
# yet reports 2 of 2 running, which reads as complete and exits early. Seen on a three node cluster
# where f5-dssm-db was still working up to its third replica.
#
# The target also depends on licensing. Without a licence f5-cne-controller logs
# "License is not enabled.. skip Resource controllers" and never creates TMM, so Available can
# never become True. A licensed run waits for Available. An unlicensed run waits for every
# condition that a licence does not gate.
deadline=$(( $(date +%s) + ${BNK_WAIT_TIMEOUT:-900} ))
avail=""; pending=""; conds=""
while [[ $(date +%s) -lt $deadline ]]; do
  conds=$(kubectl get cneinstance f5-bnk-instance -n "$NS_BNK" \
            -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null || true)
  avail=$(printf '%s\n' "$conds" | tr ' ' '\n' | sed -n 's/^Available=//p' | head -1)
  if [[ "$avail" == "True" ]]; then break; fi

  if [[ "${SKIP_LICENSE:-0}" == "1" ]]; then
    pending=$(printf '%s\n' "$conds" | tr ' ' '\n' | grep '=False$' \
                | grep -vE '^(Available|F5TmmAvailable)=' | sed 's/=False//' | paste -sd, - || true)

    # The absence of a False condition does not mean ready. Moments after the CNEInstance is
    # created the operator has not populated its component conditions yet, so nothing is False
    # simply because nothing is there. Waiting on that alone declared success 0.12 seconds after
    # apply, with one pod running, on a fresh cluster.
    #
    # Reconciled=True is the operator saying it has finished laying the stack out, and the
    # component conditions have to actually be present, so require both.
    reconciled=$(printf '%s\n' "$conds" | tr ' ' '\n' | sed -n 's/^Reconciled=//p' | head -1)
    components=$(printf '%s\n' "$conds" | tr ' ' '\n' | grep -cE '^[A-Za-z]+Available=True$' || true)
    if [[ -z "$pending" && "$reconciled" == "True" && "${components:-0}" -ge 5 ]]; then break; fi
    if [[ -z "$pending" ]]; then
      pending="reconciling, ${components:-0} components up"
    fi
  else
    pending=$(printf '%s\n' "$conds" | tr ' ' '\n' | grep '=False$' \
                | sed 's/=False//' | paste -sd, - || true)
  fi
  printf '\r    waiting, outstanding: %-58s' "${pending:-starting up}"
  progress_shown=1
  sleep 15
done
[[ "${progress_shown:-0}" == "1" ]] && printf '\r%-80s\r' ' '

if [[ "$avail" == "True" ]]; then
  ok "CNEInstance Available"
elif [[ "${SKIP_LICENSE:-0}" == "1" && -z "$pending" && -n "$conds" ]]; then
  ok "control plane ready. Available stays False without a licence, which is expected"
else
  warn "CNEInstance did not become ready within ${BNK_WAIT_TIMEOUT:-900}s"
  kubectl get cneinstance f5-bnk-instance -n "$NS_BNK" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null \
    | grep -v '=True' | sed 's/^/        /' || true
  # A workload short of its desired replicas is usually the cause. Printed with awk rather than
  # python, because nesting escaped quotes inside a heredoc inside a shell string is how the
  # previous version of this became a SyntaxError that only surfaced when it finally ran.
  kubectl get sts,deploy -n "$NS_BNK" \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,WANT:.spec.replicas,READY:.status.readyReplicas' \
    --no-headers 2>/dev/null \
    | awk '{ ready = ($4 == "<none>" ? 0 : $4); if (ready != $3) printf "        %s/%s: %s/%s ready\n", $1, $2, ready, $3 }' \
    || true

    # Say whether this is slow or broken, because the two need opposite responses and nothing above
    # distinguishes them. A stack still pulling images looks identical to a stack that will never come
    # up, right until you count what the pods are actually doing.
    for ns in "$NS_CORE" "$NS_BNK"; do
      phases=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
                 | awk '{c[$3]++} END {for (p in c) printf "%s=%s ", p, c[p]}')
      [[ -n "$phases" ]] && echo "        $ns pods: $phases"
    done
    # A container in ContainerCreating with no pull error means the only thing wrong is the timeout.
    waiting=$(kubectl get pods -A \
                -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
                | grep -c . || true)
    stuck=$(kubectl get pods -A \
              -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
              | grep -c 'ImagePullBackOff\|ErrImagePull\|CrashLoopBackOff' || true)
    if [[ "${waiting:-0}" -gt 0 && "${stuck:-0}" -eq 0 ]]; then
      warn "${waiting} container(s) still waiting and none of them failed a pull, so the stack is coming up and this is a timeout rather than a failure. Raise BNK_WAIT_TIMEOUT, currently ${BNK_WAIT_TIMEOUT:-900}s."
    elif [[ "${stuck:-0}" -gt 0 ]]; then
      warn "${stuck} container(s) are failing to pull or crash looping, which is a real failure rather than slowness."
    fi
fi
