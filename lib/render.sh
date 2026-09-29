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
    | awk -v blk="$attach_block" -v cr="$calico_router" '
        $0 == "__ATTACHMENTS__"   { if (blk != "") print blk; next }
        $0 == "__CALICOROUTER__"  { if (cr  != "") print cr;  next }
        { print }'
}
