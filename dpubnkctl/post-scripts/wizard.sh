#!/usr/bin/env bash
# Runs on the jumphost after discover wizard. Corrects poc.yaml so the deployment does not
# depend on whatever discovery guessed. Everything it writes comes from env/<site>.env.
set -euo pipefail
source "${SITE_ENV:?SITE_ENV must point at env/<site>.env}"
POC_DIR="${POC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PY="${POC_DIR}/poc.yaml"
[[ -r "$PY" ]] || { echo "no poc.yaml at $PY"; exit 1; }
command -v yq >/dev/null || { echo "yq not installed on the jumphost"; exit 1; }

cp "$PY" "${PY}.pre-wizard"

yq -i ".dpu.count = ${WIZARD_DPU_COUNT}" "$PY"
yq -i ".dpu.lag.enabled = ${WIZARD_LAG_ENABLED}" "$PY"
yq -i ".host.interfaces.external = \"${HOST_EXT_IFACE}\"" "$PY"
yq -i ".host.interfaces.internal = \"${HOST_INT_IFACE}\"" "$PY"
if [[ -n "${WIZARD_NFS_SERVER:-}" ]]; then
  yq -i ".storage.nfs.server = \"${WIZARD_NFS_SERVER}\"" "$PY"
  yq -i ".storage.nfs.path = \"${WIZARD_NFS_PATH}\"" "$PY"
fi

echo "poc.yaml corrected. diff against discovery:"
diff "${PY}.pre-wizard" "$PY" || true
echo "wizard post-script done"
