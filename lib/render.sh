# Renders a CNEInstance from a profile template plus the current environment and profile settings.
#
# Sourced by 50-cneinstance.sh and by tests/render.sh, so there is exactly one definition of how an
# object is produced. When this lived in two places, adding a placeholder to the renderer left the
# test substituting an older set and the test silently stopped proving anything.
render_cneinstance() {
  local prof="$1"
  [[ -r "$prof" ]] || { echo "no profile template at $prof" >&2; return 1; }

  # networkAttachments is a list, so it is built rather than substituted. Host mode renders none.
  local attach_block="" a
  if [[ -n "${BNK_NETWORK_ATTACHMENTS:-}" ]]; then
    attach_block="  networkAttachments:"
    local -a _na
    IFS=',' read -ra _na <<< "$BNK_NETWORK_ATTACHMENTS"
    for a in "${_na[@]}"; do attach_block+=$'\n'"    - ${a}"; done
  fi

  # TMM_CALICO_ROUTER applies only on Calico. The documented preflight runs extra pod CIDR and TMM
  # env var checks for Calico specifically, so setting it on Flannel or OVN would be wrong.
  local calico_router=""
  if [[ "${BNK_DETECTED_CNI:-calico}" == "calico" ]]; then
    calico_router=$'        - name: TMM_CALICO_ROUTER\n          value: default'
  fi

  # Cluster scope. With product.gatewayAPI true the admission webhook insists wholeCluster and
  # watchNamespaces agree: "Invalid product configuration, please check WholeCluster, WatchNamespaces and
  # GatewayAPI settings". The CRD says watchNamespaces must be empty when wholeCluster is true.
  #
  # wholeCluster defaults to false in the CRD. Setting it true, which this repository used to do
  # unconditionally, sends the lifecycle operator down cluster wide route programming, and that path
  # panics. "Adding TMM TMM_K8S_ROUTES environment variables" is followed in the same millisecond by
  # "Observed a panic: assignment to entry in nil map" at f5tmm_daemonset.go:186. The panic aborts the
  # DaemonSet build, so on a fresh cluster TMM is never created and no status says why. An existing
  # DaemonSet survives it, which is why a long lived cluster looks healthy.
  #
  # Naming the namespaces is therefore the working mode. Set BNK_WATCH_NAMESPACES to a comma separated
  # list. Leave it empty for whole cluster mode, on a release where that panic is fixed.
  local scope_block="  wholeCluster: true" ns
  if [[ -n "${BNK_WATCH_NAMESPACES:-}" ]]; then
    scope_block="  wholeCluster: false"$'\n'"  watchNamespaces:"
    local -a _ns
    IFS=',' read -ra _ns <<< "$BNK_WATCH_NAMESPACES"
    for ns in "${_ns[@]}"; do scope_block+=$'\n'"    - ${ns}"; done
  fi

  sed -e "s|__MANIFEST__|${CNE_RELEASE_MANIFEST}|g" \
      -e "s|__REPO__|${CNE_REPO}|g" \
      -e "s|__ISSUER__|${CLUSTER_ISSUER}|g" \
      -e "s|__STORAGECLASS__|${_render_sc}|g" \
      -e "s|__PODCIDR__|${BNK_POD_CIDR:-192.168.0.0/16}|g" \
      -e "s|__SIZE__|${BNK_DEPLOYMENT_SIZE:-Small}|g" \
      -e "s|__MTU__|${BNK_TMM_MTU:-1500}|g" \
      -e "s|__DYNROUTE__|${BNK_DYNAMIC_ROUTING:-false}|g" \
      -e "s|__CORECOLLECT__|${BNK_CORE_COLLECTION:-false}|g" \
      -e "s|__DPUENABLED__|${BNK_DPU_ENABLED:-false}|g" \
      -e "s|__ZEBOS__|${BNK_ZEBOS_STATE:-}|g" \
      "$prof" \
    | awk -v blk="$attach_block" -v cr="$calico_router" -v sb="$scope_block" '
        $0 == "__ATTACHMENTS__"   { if (blk != "") print blk; next }
        $0 == "__CALICOROUTER__"  { if (cr  != "") print cr;  next }
          $0 == "__CLUSTERSCOPE__"  { print sb; next }
        { print }'
}
