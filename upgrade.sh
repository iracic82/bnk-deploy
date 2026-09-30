#!/usr/bin/env bash
# Upgrade a BNK installation, with a health gate and automatic rollback.
#
# The documented FLO upgrade is four steps: helm upgrade the Lifecycle Operator, run any data
# migrations, raise manifestVersion on the CNEInstance, and re-apply the License. Rollback is
# documented for Helm installed components as `helm rollback <release> <revision>`, which is the
# mechanism this uses for FLO, paired with restoring manifestVersion on the CNEInstance.
#
# WHAT ROLLBACK CANNOT UNDO. Some releases carry one way data migrations. Going from 2.2.1 to 2.3.0
# migrates cpcl-config-cm and cpcl-key-cm from ConfigMaps to Secrets because the new CWC requires
# Secrets. Rolling the operator back across that boundary leaves components looking for the old
# shape. This script detects a crossed migration boundary and refuses to roll back automatically,
# because a rollback that silently corrupts state is worse than a failed upgrade. Restore from your
# own backup in that case.
#
# Usage:
#   ./upgrade.sh --env production --profile dpu --to 2.3.0-3.2598.3-0.0.170
#   ./upgrade.sh --env lab --to <manifest> --dry-run          plan only, change nothing
#   ./upgrade.sh --env lab --to <manifest> --no-rollback      leave a failure in place to inspect
#   ./upgrade.sh --env lab --rollback-to snapshots/<file>     roll back a previous upgrade
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BNK_ENV=""; PROFILE_OVERRIDE=""; TARGET=""; DRY_RUN=0; AUTO_ROLLBACK=1; ROLLBACK_FROM=""
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
SNAP_DIR="${BNK_SNAPSHOT_DIR:-$HERE/snapshots}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) BNK_ENV="$2"; shift 2 ;;
    --profile) PROFILE_OVERRIDE="$2"; shift 2 ;;
    --to) TARGET="$2"; shift 2 ;;
    --context) KUBE_CONTEXT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-rollback) AUTO_ROLLBACK=0; shift ;;
    --rollback-to) ROLLBACK_FROM="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
source "$HERE/versions.env"
[[ -n "$BNK_ENV" ]] || { echo "pass --env <name>"; exit 2; }
# shellcheck disable=SC1090
source "$HERE/environments/${BNK_ENV}.env"
PROFILE="${PROFILE_OVERRIDE:-${BNK_DEFAULT_PROFILE:-host}}"
# shellcheck disable=SC1090
source "$HERE/profiles/${PROFILE}.env"
combo="$HERE/environments/${BNK_ENV}.${PROFILE}.env"
# shellcheck disable=SC1090
[[ -r "$combo" ]] && source "$combo"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[0;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '    \033[0;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }

[[ -n "$KUBE_CONTEXT" ]] && { kubectl config use-context "$KUBE_CONTEXT" >/dev/null || die "no context $KUBE_CONTEXT"; }
CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------- snapshot helpers
snapshot() {
  local f="$1"
  mkdir -p "$(dirname "$f")"
  {
    echo "# BNK state snapshot, taken before an upgrade. Used by --rollback-to."
    echo "SNAPSHOT_CONTEXT=$CTX"
    echo "SNAPSHOT_ENV=$BNK_ENV"
    echo "SNAPSHOT_PROFILE=$PROFILE"
    echo "FLO_HELM_REVISION=$(helm history f5-lifecycle-operator -n "$NS_CORE" -o json 2>/dev/null \
        | python3 -c 'import json,sys; h=json.load(sys.stdin); print(max(r["revision"] for r in h))' 2>/dev/null || echo 0)"
    echo "FLO_CHART_VERSION=$(helm list -n "$NS_CORE" -o json 2>/dev/null \
        | python3 -c 'import json,sys; [print(r["chart"].rsplit("-",1)[-1]) for r in json.load(sys.stdin) if r["name"]=="f5-lifecycle-operator"]' 2>/dev/null || echo unknown)"
    echo "MANIFEST_VERSION=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance -o jsonpath='{.spec.manifestVersion}' 2>/dev/null || echo unknown)"
    echo "CPCL_SHAPE=$(kubectl get secret cpcl-config-secret -n "$NS_CORE" >/dev/null 2>&1 && echo secret || echo configmap)"
  } > "$f"
  # the full CNEInstance, so a rollback restores the object rather than guessing at it
  kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance -o yaml 2>/dev/null \
    | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); d.pop("status",None); m=d.get("metadata",{}); [m.pop(k,None) for k in ("resourceVersion","uid","generation","creationTimestamp","managedFields")]; print(yaml.safe_dump(d))' \
    > "${f%.env}.cneinstance.yaml" 2>/dev/null || true
}

# The FLO chart renders external-otelsvr-secret, and the OTEL certificates create a cert-manager
# Certificate with that same secretName and rotationPolicy Always. Both therefore manage the secret,
# and a helm operation that renders a lookup on it can land mid rotation and fail with
# "no Secret with the name ... found". Observed once, and it succeeded on retry seconds later.
helm_retry() {
  local what="$1"; shift
  local attempt=1 max=4 delay=15
  while :; do
    if "$@" >/dev/null 2>"$_HELM_ERR"; then return 0; fi
    if grep -q 'no Secret with the name' "$_HELM_ERR" && [[ "$attempt" -lt "$max" ]]; then
      warn "$what lost a race with a certificate rotation, retrying in ${delay}s (attempt ${attempt}/${max})"
      sleep "$delay"; attempt=$((attempt+1)); continue
    fi
    sed 's/^/        /' "$_HELM_ERR" >&2
    return 1
  done
}
_HELM_ERR="$(mktemp)"
trap 'rm -f "$_HELM_ERR"' EXIT

# Healthy is not the same as upgraded. A manifestVersion that does not exist was accepted by the
# operator, nothing degraded, and Available stayed True, so a gate on health alone reports success
# for an upgrade that did nothing. This also requires the operator to have observed the new spec and
# the spec to actually carry the target.
health_gate() {
  local want="${2:-}"
  local deadline=$(( $(date +%s) + ${1:-900} )) avail tmm gen obs spec
  while [[ $(date +%s) -lt $deadline ]]; do
    gen=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)
    obs=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].observedGeneration}' 2>/dev/null || echo -1)
    avail=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance \
              -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    tmm=$(kubectl get ds -n "$NS_BNK" f5-tmm -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    spec=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance -o jsonpath='{.spec.manifestVersion}' 2>/dev/null || true)

    if [[ "$avail" == "True" && "${tmm:-0}" -ge 1 && "${obs:-0}" == "${gen:-1}" ]] \
       && { [[ -z "$want" ]] || [[ "$spec" == "$want" ]]; }; then
      return 0
    fi
    printf '\r    gate: Available=%-5s TMM=%-3s observed=%s/%s%s' \
      "${avail:-?}" "${tmm:-0}" "${obs:-?}" "${gen:-?}" "$([[ -n "$want" && "$spec" != "$want" ]] && echo " spec not yet ${want}")"
    sleep 15
  done
  printf '\r%-78s\r' ' '
  return 1
}

# ---------------------------------------------------------------- rollback path
if [[ -n "$ROLLBACK_FROM" ]]; then
  [[ -r "$ROLLBACK_FROM" ]] || die "no snapshot at $ROLLBACK_FROM"
  # shellcheck disable=SC1090
  source "$ROLLBACK_FROM"
  log "Rolling back ${SNAPSHOT_ENV} on ${SNAPSHOT_CONTEXT}"
  [[ "$CTX" == "$SNAPSHOT_CONTEXT" ]] || die "snapshot is for context ${SNAPSHOT_CONTEXT}, current is ${CTX}"

  now_shape=$(kubectl get secret cpcl-config-secret -n "$NS_CORE" >/dev/null 2>&1 && echo secret || echo configmap)
  if [[ "$CPCL_SHAPE" != "$now_shape" ]]; then
    die "a one way data migration has run since this snapshot (cpcl was ${CPCL_SHAPE}, is now ${now_shape}). Rolling the operator back would leave components looking for the old shape. Restore from backup instead."
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    ok "would helm rollback f5-lifecycle-operator to revision ${FLO_HELM_REVISION}"
    ok "would restore manifestVersion ${MANIFEST_VERSION}"
    exit 0
  fi
  if helm_retry "rollback" helm rollback f5-lifecycle-operator "$FLO_HELM_REVISION" -n "$NS_CORE"; then
    ok "operator rolled back to helm revision ${FLO_HELM_REVISION}"
  else
    die "helm rollback failed"
  fi
  kubectl patch cneinstance f5-bnk-instance -n "$NS_BNK" --type=merge \
    -p "{\"spec\":{\"manifestVersion\":\"${MANIFEST_VERSION}\"}}" >/dev/null \
    && ok "manifestVersion restored to ${MANIFEST_VERSION}"
  log "Health gate after rollback"
  if health_gate "${BNK_WAIT_TIMEOUT:-1800}" "$MANIFEST_VERSION"; then
    ok "healthy and back on ${MANIFEST_VERSION}"
  else
    warn "did not reach healthy within the timeout, inspect manually"
  fi
  exit 0
fi

# ---------------------------------------------------------------- upgrade path
[[ -n "$TARGET" ]] || die "pass --to <manifest-version>, for example --to ${CNE_RELEASE_MANIFEST}"

printf '\n\033[1m  BNK upgrade  env=%s  profile=%s  context=%s%s\033[0m\n' \
  "$BNK_ENV" "$PROFILE" "$CTX" "$([[ $DRY_RUN == 1 ]] && echo '  [dry-run]')"

log "Pre-checks"
rel_status=$(helm list -n "$NS_CORE" -o json 2>/dev/null \
  | python3 -c 'import json,sys;print(next((r["status"] for r in json.load(sys.stdin) if r["name"]=="f5-lifecycle-operator"),"missing"))' 2>/dev/null || echo unknown)
case "$rel_status" in
  deployed) ok "helm release is deployed" ;;
  missing)  die "no f5-lifecycle-operator helm release. Upgrade applies to an existing install." ;;
  *)        die "helm release is in state '${rel_status}'. Resolve that first, helm history f5-lifecycle-operator -n ${NS_CORE}" ;;
esac
current=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance -o jsonpath='{.spec.manifestVersion}' 2>/dev/null || true)
[[ -n "$current" ]] || die "no CNEInstance found. Upgrade applies to an existing install, use install.sh first."
ok "currently on ${current}"
[[ "$current" != "$TARGET" ]] || die "already on ${TARGET}, nothing to do"

# Prove the target exists before changing anything. A manifestVersion that does not exist is
# accepted by the operator without complaint: it is recorded, Available stays True, nothing degrades,
# and the upgrade reports success while having done nothing, because no component needs to pull new
# charts until something forces a re-render. Verified by setting 9.9.9-does-not-exist on a healthy
# cluster. So resolving the target against the registry is the only reliable check.
if helm show chart "oci://${CNE_REPO}/release/${CNE_CHART:-f5-bigip-k8s-manifest}" --version "$TARGET" >/dev/null 2>&1; then
  ok "target ${TARGET} resolves in the registry"
else
  die "manifest version ${TARGET} does not exist in ${CNE_REPO}. The operator would accept it silently and the upgrade would appear to succeed while changing nothing."
fi

# Never upgrade a cluster that is not healthy now. Otherwise a pre-existing fault looks like
# upgrade damage and the rollback target is a broken state.
avail=$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
[[ "$avail" == "True" ]] || die "CNEInstance is Available=${avail:-unset}. Fix the current install before upgrading, or there is nothing safe to roll back to."
ok "current install is healthy"

stamp="$(kubectl get cneinstance -n "$NS_BNK" f5-bnk-instance -o jsonpath='{.metadata.generation}' 2>/dev/null)-${current}"
snap="${SNAP_DIR}/${BNK_ENV}-${CTX}-gen${stamp}.env"
if [[ "$DRY_RUN" == "1" ]]; then
  ok "would snapshot state to ${snap}"
  ok "would helm upgrade f5-lifecycle-operator to ${FLO_VERSION}"
  ok "would set manifestVersion ${current} -> ${TARGET}"
  ok "would gate on Available=True and TMM ready, rolling back on failure"
  log "Dry run complete, nothing changed"
  exit 0
fi

log "Snapshot"
snapshot "$snap"
ok "state recorded at ${snap#"$HERE"/}"
grep -E '^(FLO_HELM_REVISION|MANIFEST_VERSION|CPCL_SHAPE)=' "$snap" | sed 's/^/        /'

log "Upgrade the Lifecycle Operator"
if helm_retry "upgrade" helm upgrade f5-lifecycle-operator "oci://${CNE_REPO}/charts/f5-lifecycle-operator" \
     --version "$FLO_VERSION" --namespace "$NS_CORE" --reuse-values; then
  ok "operator at ${FLO_VERSION}"
else
  die "helm upgrade failed. Nothing else was changed, so the install is untouched."
fi
if kubectl -n "$NS_CORE" rollout status deploy/f5-lifecycle-operator --timeout=300s >/dev/null; then
  ok "operator rolled out"
else
  die "operator did not roll out. Roll back with: ./upgrade.sh --env ${BNK_ENV} --rollback-to ${snap#"$HERE"/}"
fi

log "Raise the CNEInstance manifest version"
kubectl patch cneinstance f5-bnk-instance -n "$NS_BNK" --type=merge \
  -p "{\"spec\":{\"manifestVersion\":\"${TARGET}\"}}" >/dev/null \
  && ok "manifestVersion ${current} -> ${TARGET}"

log "Health gate"
if health_gate "${BNK_WAIT_TIMEOUT:-1800}" "$TARGET"; then
  ok "Available=True, TMM ready, and the operator has observed manifestVersion ${TARGET}"
  log "Verify"
  if FAR_PULL_JSON="${FAR_PULL_JSON:-}" "$HERE/install.sh" --env "$BNK_ENV" --profile "$PROFILE" --phase 70; then
    ok "verification passed"
  else
    warn "verification reported problems. The upgrade is in place, so inspect before deciding whether to roll back."
  fi
  log "Done  upgraded to ${TARGET}"
  echo "    snapshot kept at ${snap#"$HERE"/} in case you need to roll back later"
else
  warn "health gate failed: Available did not reach True with TMM ready"
  if [[ "$AUTO_ROLLBACK" == "0" ]]; then
    die "--no-rollback given, leaving the failure in place. Roll back with: ./upgrade.sh --env ${BNK_ENV} --rollback-to ${snap#"$HERE"/}"
  fi
  log "Rolling back automatically"
  exec "$0" --env "$BNK_ENV" --profile "$PROFILE" --rollback-to "$snap"
fi
