#!/usr/bin/env bash
# Runs on the jumphost after the provision phase. Configures the OVS bridges on the DPU.
# Replaces the manual "After Phase 3" block in F5's procedure.
# Idempotent: bridges are deleted before being recreated, and addresses are only added if absent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SITE_ENV:?SITE_ENV must point at env/<site>.env}"

POC_DIR="${POC_DIR:-$HERE/..}"
PW_FILE="${POC_DIR}/keys/dpu_password.txt"
[[ -r "$PW_FILE" ]] || { echo "no DPU password at $PW_FILE"; exit 1; }

command -v sshpass >/dev/null || { echo "sshpass not installed on the jumphost"; exit 1; }

# The DPU host key changes on every reflash, so clear it rather than failing on a mismatch.
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DPU_ADDR" >/dev/null 2>&1 || true

export SSHPASS="$(tr -d '\r\n' < "$PW_FILE")"
dpu() { sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${DPU_ADDR}" "$@"; }

echo "configuring OVS bridges on ${DPU_ADDR}"
dpu sudo bash -s <<REMOTE
set -euo pipefail
for br in "${DPU_EXT_BRIDGE}" "${DPU_INT_BRIDGE}"; do
  ovs-vsctl --if-exists del-br "\$br"
done

ovs-vsctl add-br "${DPU_EXT_BRIDGE}"
ovs-vsctl add-port "${DPU_EXT_BRIDGE}" "${DPU_EXT_UPLINK}"
ovs-vsctl add-port "${DPU_EXT_BRIDGE}" "${DPU_EXT_SF_REP}"
ovs-vsctl add-port "${DPU_EXT_BRIDGE}" "${DPU_EXT_PF_REP}"

ovs-vsctl add-br "${DPU_INT_BRIDGE}"
ovs-vsctl add-port "${DPU_INT_BRIDGE}" "${DPU_INT_UPLINK}"
ovs-vsctl add-port "${DPU_INT_BRIDGE}" "${DPU_INT_SF_REP}"
ovs-vsctl add-port "${DPU_INT_BRIDGE}" "${DPU_INT_PF_REP}"

ip link set "${DPU_EXT_BRIDGE}" up
ip link set "${DPU_INT_BRIDGE}" up
ip addr replace "${DPU_EXT_ADDR}" dev "${DPU_EXT_BRIDGE}"
ip addr replace "${DPU_INT_ADDR}" dev "${DPU_INT_BRIDGE}"

echo "--- bridges ---"; ovs-vsctl show | grep -E 'Bridge|Port' | head -20
echo "--- addresses ---"; ip -brief addr show | grep -E "${DPU_EXT_BRIDGE}|${DPU_INT_BRIDGE}"
REMOTE
echo "provision post-script done"
