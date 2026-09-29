#!/usr/bin/env bash
# Runs on the jumphost after the host-network phase. Applies the dataplane netplan on the host
# and proves both paths to the DPU. Replaces the manual "After Phase 4" block.
set -euo pipefail
source "${SITE_ENV:?SITE_ENV must point at env/<site>.env}"
host() { ssh -o StrictHostKeyChecking=no "${HOST_USER}@${HOST_ADDR}" "$@"; }

echo "applying dataplane netplan on ${HOST_ADDR}"
host sudo bash -s <<REMOTE
set -euo pipefail
cat > /etc/netplan/70-dpubnkctl-dataplane.yaml <<'NETPLAN'
network:
  version: 2
  renderer: networkd
  ethernets:
    ${HOST_EXT_IFACE}:
      mtu: ${HOST_DATAPLANE_MTU}
      addresses:
        - ${HOST_EXT_ADDR}
    ${HOST_INT_IFACE}:
      mtu: ${HOST_DATAPLANE_MTU}
      addresses:
        - ${HOST_INT_ADDR}
NETPLAN
chmod 600 /etc/netplan/70-dpubnkctl-dataplane.yaml
netplan apply

# remove interfaces a previous run may have left behind
for l in ${HOST_STALE_LINKS:-}; do ip link del "\$l" 2>/dev/null || true; done
REMOTE

# Both paths must work before the cluster comes up, so fail loudly here rather than later.
ext_peer="${DPU_EXT_ADDR%%/*}"; int_peer="${DPU_INT_ADDR%%/*}"
for peer in "$ext_peer" "$int_peer"; do
  if host ping -c 3 -W 2 "$peer" >/dev/null 2>&1; then
    echo "  host to DPU ${peer} ok"
  else
    echo "  host cannot reach DPU ${peer}. Check the bridge port membership and the PF names."; exit 1
  fi
done
echo "host-network post-script done"
