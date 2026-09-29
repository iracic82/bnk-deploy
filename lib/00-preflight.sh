# Preflight. Fails fast on the things that silently break the install later.
: "${FAR_PULL_JSON:?FAR_PULL_JSON must point at cne_pull_64.json}"
[[ -r "$FAR_PULL_JSON" ]] || die "cannot read $FAR_PULL_JSON"
for c in kubectl helm openssl base64 tar; do command -v "$c" >/dev/null || die "$c not on PATH"; done
ok "tooling present"

kubectl version --request-timeout=15s >/dev/null 2>&1 || die "no reachable cluster, check KUBECONFIG"
srv=$(kubectl version -o json 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\)".*/\1/p' | tail -1)
maj=$(kubectl version -o json 2>/dev/null | sed -n 's/.*"major": *"\([0-9]*\)".*/\1/p' | tail -1)
ok "cluster ${maj}.${srv}"
want="${K8S_MINOR#*.}"
if [[ -n "$srv" && "$srv" != "$want" ]]; then
  warn "cluster minor ${srv} differs from the tested ${K8S_MINOR}. BNK ${BNK_VERSION} is qualified on ${K8S_MINOR}."
fi

# CNI. FLO's own preflight identifies the CNI type and blocks with an ERROR if it cannot place it
# in a supported family. Per the 2.3 software requirements, Calico v3.27.0 is the "Primary CNI.
# Other CNIs may work but are not tested", and the documented check recognises Calico, Flannel,
# VPC-CNI on EKS and OCI-CNI on Oracle. OVN-Kubernetes is the supported CNI on OpenShift.
# Cilium is not mentioned anywhere in the 964 page documentation.
detect_cni() {
  local pods; pods=$(kubectl get pods -A -o name 2>/dev/null || true)
  case "$pods" in
    *calico*)   echo calico ;;
    *cilium*)   echo cilium ;;
    *ovnkube*|*ovn-kubernetes*) echo ovn-kubernetes ;;
    *flannel*)  echo flannel ;;
    *aws-node*) echo vpc-cni ;;
    *)          echo unknown ;;
  esac
}
BNK_DETECTED_CNI="$(detect_cni)"
export BNK_DETECTED_CNI
case "$BNK_DETECTED_CNI" in
  calico)
    ok "CNI calico, the primary supported CNI"
    ;;
  flannel|vpc-cni|ovn-kubernetes)
    ok "CNI ${BNK_DETECTED_CNI}, recognised by the FLO preflight"
    warn "${BNK_DETECTED_CNI} is recognised but not the primary CNI. Calico is the only one F5 tests."
    ;;
  cilium)
    warn "CNI cilium. It appears nowhere in the BNK 2.3 documentation and is not in the set the FLO preflight recognises, so FLO may block the install with an ERROR. Use Calico unless you are deliberately testing this."
    ;;
  *)
    warn "could not identify the CNI. FLO blocks with an ERROR when it cannot place the CNI in a supported family."
    ;;
esac

# THE blocker the install guide never mentions. FLO watches NetworkAttachmentDefinition at
# startup and crash loops with 'if kind is a CRD, it should be installed before calling Start'
# if the Multus CRD is absent, even for a host install that uses no attachments.
if kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1; then
  ok "NetworkAttachmentDefinition CRD present"
else
  warn "Multus CRD absent. Phase 10 installs it. FLO cannot start without it."
fi

kubectl get sc --no-headers 2>/dev/null | grep -q . || die "no StorageClass. BNK needs persistent volumes."
ok "storageclass: $(kubectl get sc --no-headers | awk '$2!=""{print $1}' | head -1)"

# TMM requests hugepages-2Mi in every profile, and the operator keeps that request even if you
# override advanced.tmm.resources to remove it. So this is mandatory wherever TMM will run.
if [[ "${BNK_NEEDS_HUGEPAGES:-true}" == "true" ]]; then
  hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ "${hp:-0}" -gt 0 ]]; then ok "hugepages: $hp"; else
    warn "no hugepages on this node. TMM will stay Pending. sysctl -w vm.nr_hugepages=2048"
  fi
fi

# DPU profile only. Node provisioning must already have happened.
if [[ "${BNK_NEEDS_SRIOV:-false}" == "true" ]]; then
  if kubectl get nodes -o json | grep -q 'nvidia.com/bf3_'; then
    ok "SR-IOV scalable function resources advertised by a node"
  else
    warn "no node advertises nvidia.com/bf3_* resources. The DPU profile needs the SR-IOV device plugin and scalable functions. Use dpubnkctl/run.sh if the nodes are not provisioned."
  fi
  for a in ${BNK_NETWORK_ATTACHMENTS//,/ }; do
    if kubectl get net-attach-def "$a" -n "$NS_BNK" >/dev/null 2>&1; then
      ok "NetworkAttachmentDefinition $a present"
    else
      warn "NetworkAttachmentDefinition $a missing in $NS_BNK"
    fi
  done
fi
ok "profile ${BNK_PROFILE_NAME:-host}, dpu=${BNK_DPU_ENABLED:-false}, mtu=${BNK_TMM_MTU:-1500}"
