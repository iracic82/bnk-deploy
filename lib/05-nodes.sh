# Node preparation. Which nodes run TMM, and what has to be true of them.
#
# The docs make this a required step and give it no useful failure mode. From the host path:
# "Label each node that you want TMM pods to run on. If no nodes are labeled, the
# container-orchestration platform won't schedule any TMM pods." Skip it and the operator panics
# with "assignment to entry in nil map" at f5tmm_daemonset.go:186, naming neither TMM nor the label.
#
# The DPU path needs more. Phase 5 of the DPU workflow: "apply the DPU node label so Kubernetes
# knows to schedule TMM there, taint the DPU node to block other workloads, and install the SR-IOV
# Network Device Plugin." The taint is dpu=true:NoSchedule, and the docs say to apply it to every
# DPU node so that only TMM and permitted system pods land there.

TMM_LABEL="app=f5-tmm"
DPU_TAINT="dpu=true:NoSchedule"

# Which nodes should run TMM comes from the cluster file, so where BNK installs is declared rather
# than discovered. With none declared we only verify, never guess.
declared_nodes="${BNK_TMM_NODES:-}"
manage="${BNK_TMM_MANAGE_LABELS:-false}"

if [[ -n "$declared_nodes" ]]; then
  ok "cluster declares TMM nodes: ${declared_nodes//,/ }"
  for n in ${declared_nodes//,/ }; do
    if ! kubectl get node "$n" >/dev/null 2>&1; then
      die "cluster file names TMM node '$n' but it is not in this cluster"
    fi
  done
fi

if [[ "$manage" == "true" && -n "$declared_nodes" ]]; then
  [[ "$DRY_RUN" == "1" ]] && { warn "dry run, not labelling or tainting"; return 0; }
  for n in ${declared_nodes//,/ }; do
    kubectl label node "$n" "$TMM_LABEL" --overwrite >/dev/null
    ok "labelled $n $TMM_LABEL"
    if [[ "${BNK_DPU_ENABLED:-false}" == "true" ]]; then
      # idempotent: adding a taint that is already present is not an error with --overwrite
      kubectl taint node "$n" "$DPU_TAINT" --overwrite >/dev/null
      ok "tainted $n $DPU_TAINT so only TMM and permitted system pods land there"
    fi
  done
fi

# Whether we applied them or not, the cluster has to end up correct.
labelled=$(kubectl get nodes -l "$TMM_LABEL" --no-headers 2>/dev/null | wc -l)
if [[ "${labelled:-0}" -eq 0 ]]; then
  if [[ -n "$declared_nodes" && "$manage" != "true" ]]; then
    die "no node carries $TMM_LABEL. The cluster file declares ${declared_nodes} but tmm.manage_labels is false, so apply it yourself: kubectl label node ${declared_nodes%%,*} $TMM_LABEL"
  fi
  die "no node carries $TMM_LABEL, so TMM will never be scheduled. Declare tmm.nodes in the cluster file, or label one: kubectl label node <NODE> $TMM_LABEL"
fi
ok "$labelled node(s) carry $TMM_LABEL"

# More than one TMM node breaks BNK 2.3. Measured on a running cluster: with one labelled node the
# F5Tmm resource is Available and the DaemonSet is desired=1 ready=1. Label a second and within 45
# seconds the lifecycle operator logs 12 panics, "assignment to entry in nil map" at
# f5tmm_daemonset.go:186, F5Tmm goes Available=False, the CNEInstance goes Available=False, and the
# second TMM pod never gets all its containers ready. Removing the label restores Available=True
# immediately.
#
# On a cluster where the DaemonSet already exists it survives in that degraded state. On a fresh
# install the panic loop means the DaemonSet is never created at all, and the symptom is TMM simply
# never appearing with no error that mentions labels.
#
# Set BNK_TMM_ALLOW_MULTI=true to proceed anyway, for a release where this is fixed.
if [[ "${labelled:-0}" -gt 1 && "${BNK_TMM_ALLOW_MULTI:-false}" != "true" ]]; then
  die "$labelled nodes carry $TMM_LABEL. BNK 2.3 supports one. With two, the lifecycle operator panics in a loop at f5tmm_daemonset.go:186 and TMM is never created. Label one node, or set BNK_TMM_ALLOW_MULTI=true if your release has fixed it."
fi

# A labelled node with no hugepages cannot run TMM either, and the failure is a Pending pod rather
# than anything that mentions hugepages.
for n in $(kubectl get nodes -l "$TMM_LABEL" -o name 2>/dev/null | cut -d/ -f2); do
  hp=$(kubectl get node "$n" -o jsonpath='{.status.allocatable.hugepages-2Mi}' 2>/dev/null)
  case "${hp:-0}" in
    0|"") warn "node $n is labelled for TMM but advertises no hugepages-2Mi. TMM will stay Pending." ;;
    *)    ok "node $n has ${hp} hugepages" ;;
  esac
done

if [[ "${BNK_DPU_ENABLED:-false}" == "true" ]]; then
  tainted=$(kubectl get nodes -l "$TMM_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}={range .spec.taints[*]}{.key}:{.effect} {end}{"\n"}{end}' 2>/dev/null \
              | grep -c 'dpu:NoSchedule' || true)
  if [[ "${tainted:-0}" -gt 0 ]]; then
    ok "$tainted DPU node(s) tainted $DPU_TAINT"
  else
    warn "no TMM node carries $DPU_TAINT. The DPU path expects it so other workloads stay off the DPU."
  fi
fi
