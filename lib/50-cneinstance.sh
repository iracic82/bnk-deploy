# CNEInstance. The whole data plane shape lives in this one object.
prof="$HERE/profiles/${PROFILE}.yaml"
[[ -r "$prof" ]] || die "no profile at $prof"

sc="${BNK_STORAGECLASS:-}"
[[ -n "$sc" ]] && kubectl get sc "$sc" >/dev/null 2>&1 || sc="$(kubectl get sc -o jsonpath='{.items[0].metadata.name}')"
# TMM_CALICO_ROUTER only applies on Calico. The documented preflight "runs additional checks for
# pod CIDR and TMM env var for Calico", so injecting it on Flannel or OVN would be wrong.
calico_router=""
if [[ "${BNK_DETECTED_CNI:-calico}" == "calico" ]]; then
  calico_router=$'        - name: TMM_CALICO_ROUTER\n          value: default'
fi

# Build the networkAttachments block from the profile. Host mode renders nothing at all.
attach_block=""
if [[ -n "${BNK_NETWORK_ATTACHMENTS:-}" ]]; then
  attach_block="  networkAttachments:"
  IFS=',' read -ra _na <<< "$BNK_NETWORK_ATTACHMENTS"
  for a in "${_na[@]}"; do attach_block+=$'\n'"    - ${a}"; done
fi

rendered=$(sed -e "s|__MANIFEST__|${CNE_RELEASE_MANIFEST}|g" \
               -e "s|__REPO__|${CNE_REPO}|g" \
               -e "s|__ISSUER__|${CLUSTER_ISSUER}|g" \
               -e "s|__STORAGECLASS__|${sc}|g" \
               -e "s|__PODCIDR__|${BNK_POD_CIDR:-192.168.0.0/16}|g" \
               -e "s|__SIZE__|${BNK_DEPLOYMENT_SIZE:-Small}|g" \
               -e "s|__MTU__|${BNK_TMM_MTU:-1500}|g" \
               -e "s|__DYNROUTE__|${BNK_DYNAMIC_ROUTING:-false}|g" \
               -e "s|__CORECOLLECT__|${BNK_CORE_COLLECTION:-false}|g" \
               -e "s|__DPUENABLED__|${BNK_DPU_ENABLED:-false}|g" \
               -e "s|__ZEBOS__|${BNK_ZEBOS_STATE:-}|g" \
               "$prof" | awk -v blk="$attach_block" -v cr="$calico_router" '{ if ($0=="__ATTACHMENTS__") { if (blk!="") print blk } else if ($0=="__CALICOROUTER__") { if (cr!="") print cr } else print }')

if [[ "$DRY_RUN" == "1" ]]; then
  echo "$rendered" | kubectl apply -n "$NS_BNK" --dry-run=server -f - >/dev/null \
    && ok "CNEInstance (${PROFILE}) validates server side" || die "CNEInstance rejected"
  return 0
fi
echo "$rendered" | kubectl apply -n "$NS_BNK" -f - >/dev/null
ok "CNEInstance applied, profile ${PROFILE}"
echo "    waiting for the operator to lay down the stack, this takes several minutes"

# Do NOT wait on "running pods == total pods". A StatefulSet that has not yet created its next
# replica reports 2 of 2 running, which reads as complete and exits the wait early. Found on a
# three node cluster where f5-dssm-db was still working up to its third replica.
#
# The CNEInstance's own Available condition is the authoritative signal, and its sub-conditions
# say exactly what is outstanding. Wait on that, and report the truth on timeout rather than
# implying success.
deadline=$(( $(date +%s) + ${BNK_WAIT_TIMEOUT:-900} ))
avail=""
while [[ $(date +%s) -lt $deadline ]]; do
  avail=$(kubectl get cneinstance f5-bnk-instance -n "$NS_BNK" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  [[ "$avail" == "True" ]] && break
  pending=$(kubectl get cneinstance f5-bnk-instance -n "$NS_BNK" \
              -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null \
              | tr ' ' '\n' | grep '=False$' | sed 's/=False//' | paste -sd, - || true)
  printf '\r    waiting, outstanding: %-60s' "${pending:-starting up}"
  sleep 15
done
printf '\r%-80s\r' ' '

if [[ "$avail" == "True" ]]; then
  ok "CNEInstance Available"
else
  warn "CNEInstance did not reach Available within ${BNK_WAIT_TIMEOUT:-900}s"
  kubectl get cneinstance f5-bnk-instance -n "$NS_BNK" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null \
    | grep -v '=True' | sed 's/^/        /'
  # Show any workload that has not reached its desired replica count, which is usually the cause.
  kubectl get sts,deploy -n "$NS_BNK" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d.get("items",[]):
    want=i["spec"].get("replicas",1); got=i.get("status",{}).get("readyReplicas",0)
    if got!=want:
        print(f"        {i[\"kind\"]}/{i[\"metadata\"][\"name\"]}: {got}/{want} ready")
' 2>/dev/null || true
fi
