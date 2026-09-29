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
    # everything a licence does not gate is satisfied, so this is as far as it can get
    if [[ -z "$pending" && -n "$conds" ]]; then break; fi
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
  # a workload short of its desired replicas is usually the cause
  kubectl get sts,deploy -n "$NS_BNK" -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for i in d.get("items",[]):
    want=i["spec"].get("replicas",1); got=i.get("status",{}).get("readyReplicas",0)
    if got!=want: print(f"        {i[\"kind\"]}/{i[\"metadata\"][\"name\"]}: {got}/{want} ready")
' || true
fi
