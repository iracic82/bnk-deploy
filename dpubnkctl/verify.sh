#!/usr/bin/env bash
# Turns F5's verification block into assertions with a non zero exit.
set -uo pipefail
source "${SITE_ENV:?SITE_ENV must be set}"
POC_DIR="${POC_DIR:?POC_DIR must be set}"
KC="${POC_DIR}/artifacts/kubeconfig"
if [[ -r "$KC" ]]; then export KUBECONFIG="$KC"; k() { kubectl "$@"; }
else k() { ssh -o StrictHostKeyChecking=no "${HOST_USER}@${HOST_ADDR}" kubectl "$@"; }; fi

fails=0
chk() { if eval "$2" >/dev/null 2>&1; then printf '    \033[0;32mok\033[0m  %s\n' "$1"; else printf '    \033[0;31mXX\033[0m  %s\n' "$1"; fails=$((fails+1)); fi; }

chk "licence Active"        "k get license.k8s.f5net.com -n f5-cne-core -o jsonpath='{.items[0].status.state}' | grep -q Active"
chk "F5SPKVlans ready"      "k get f5-spk-vlans.k8s.f5net.com -n f5-bnk -o jsonpath='{.items[*].status.ready}' | grep -q True"
chk "GatewayClass accepted" "k get gatewayclass -o jsonpath='{.items[*].status.conditions[?(@.type==\"Accepted\")].status}' | grep -q True"
chk "TMM running"           "k get pods -n f5-bnk -l app=f5-tmm -o jsonpath='{.items[0].status.phase}' | grep -q Running"
chk "CNEInstance Available" "k get cneinstance -A -o jsonpath='{.items[0].status.conditions[?(@.type==\"Available\")].status}' | grep -q True"
chk "nothing crash looping" "! k get pods -A --no-headers | grep -q CrashLoopBackOff"

[[ "$fails" -gt 0 ]] && { echo "    $fails check(s) failed"; exit 1; }
echo "    all checks passed"
