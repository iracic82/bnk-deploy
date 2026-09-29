#!/usr/bin/env bash
# Automated BIG-IP Next for Kubernetes installer.
#
# One installer, four environments, two deployment profiles. Everything an operator needs to
# stand BNK up from git, idempotently, with the same code path in lab and in production.
#
# Usage:
#   ./install.sh --env lab                     lab defaults, host profile
#   ./install.sh --env production              production defaults, dpu profile, strict
#   ./install.sh --env staging --profile host  override the environment's profile
#   ./install.sh --env lab --phase 70          run one phase
#   ./install.sh --env demo --dry-run          validate server side, change nothing
#   ./install.sh --env lab --skip-license      install unlicensed
#
# Environment files live in environments/. Version pins live in versions.env. Neither holds
# secrets. Secrets come from the process environment only:
#   FAR_PULL_JSON        path to cne_pull_64.json
#   BNK_LICENSE_JWT      licence token, unless --skip-license
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BNK_ENV=""; PROFILE_OVERRIDE=""; ONLY_PHASE=""; SKIP_LICENSE=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) BNK_ENV="$2"; shift 2 ;;
    --profile) PROFILE_OVERRIDE="$2"; shift 2 ;;
    --phase) ONLY_PHASE="$2"; shift 2 ;;
    --skip-license) SKIP_LICENSE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --list-env) ls -1 "$HERE/environments" | grep -vE '\..*\.env$' | sed 's/\.env$//'; exit 0 ;;
    --list-profile) ls -1 "$HERE/profiles"/*.env | xargs -n1 basename | sed 's/\.env$//'; exit 0 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

# Layered configuration. Later files win.
#   versions.env                        pinned component versions, shared by everything
#   environments/<env>.env              environment policy: sizing, storage, strictness, timeouts
#   profiles/<profile>.env              deployment model: DPU on or off, MTU, attachments
#   environments/<env>.<profile>.env    optional, only for combinations that genuinely differ
# shellcheck disable=SC1091
source "$HERE/versions.env"

[[ -n "$BNK_ENV" ]] || {
  echo "pass --env <name>. Available: $(ls -1 "$HERE/environments" | grep -vE '\..*\.env$' | sed 's/\.env$//' | tr '\n' ' ')"
  exit 2
}
ENV_FILE="$HERE/environments/${BNK_ENV}.env"
[[ -r "$ENV_FILE" ]] || { echo "no environment at $ENV_FILE, try --list-env"; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"

# Every environment supports both profiles. The environment only supplies a default.
PROFILE="${PROFILE_OVERRIDE:-${BNK_DEFAULT_PROFILE:-host}}"
PROFILE_ENV="$HERE/profiles/${PROFILE}.env"
[[ -r "$PROFILE_ENV" ]] || { echo "no profile at $PROFILE_ENV. Available: $(ls -1 "$HERE/profiles"/*.env | xargs -n1 basename | sed 's/\.env$//' | tr '\n' ' ')"; exit 2; }
# shellcheck disable=SC1090
source "$PROFILE_ENV"

COMBO_ENV="$HERE/environments/${BNK_ENV}.${PROFILE}.env"
if [[ -r "$COMBO_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$COMBO_ENV"
  COMBO_NOTE=" (+${BNK_ENV}.${PROFILE} overrides)"
fi
export PROFILE SKIP_LICENSE DRY_RUN HERE
export BNK_ENV_NAME BNK_DEPLOYMENT_SIZE BNK_STORAGECLASS BNK_POD_CIDR BNK_TMM_MTU
export BNK_DYNAMIC_ROUTING BNK_CORE_COLLECTION BNK_LICENSE_MODE
export BNK_PROFILE_NAME BNK_DPU_ENABLED BNK_NETWORK_ATTACHMENTS BNK_ZEBOS_STATE
export BNK_NEEDS_HUGEPAGES BNK_NEEDS_SRIOV
export BNK_REQUIRE_LICENSE="${BNK_REQUIRE_LICENSE:-true}"
export BNK_STRICT_PREFLIGHT="${BNK_STRICT_PREFLIGHT:-false}"
export BNK_WAIT_TIMEOUT="${BNK_WAIT_TIMEOUT:-900}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[0;33m!!\033[0m  %s\n' "$*"
         if [[ "${BNK_STRICT_PREFLIGHT:-false}" == "true" ]]; then
           printf '    \033[0;31mXX\033[0m  strict mode, warnings are fatal in %s\n' "$BNK_ENV_NAME" >&2; exit 1
         fi; }
die()  { printf '    \033[0;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }
export -f log ok warn die

printf '\n\033[1m  BNK %s  env=%s  profile=%s  size=%s%s%s%s\033[0m\n' \
  "$BNK_VERSION" "$BNK_ENV_NAME" "$PROFILE" "$BNK_DEPLOYMENT_SIZE" "${COMBO_NOTE:-}" \
  "$([[ $DRY_RUN == 1 ]] && echo '  [dry-run]')" \
  "$([[ $SKIP_LICENSE == 1 ]] && echo '  [unlicensed]')"

PHASES=(
  "00-preflight:Preflight checks"
  "10-prereqs:Cluster prerequisites"
  "20-registry:Registry auth, namespaces, pull secrets"
  "30-flo:F5 Lifecycle Operator"
  "40-certs:CWC and OTEL certificates"
  "50-cneinstance:CNEInstance"
  "60-license:Licence"
  "70-verify:Verification"
)

for entry in "${PHASES[@]}"; do
  id="${entry%%:*}"; desc="${entry#*:}"; num="${id%%-*}"
  [[ -n "$ONLY_PHASE" && "$num" != "$ONLY_PHASE" ]] && continue
  if [[ "$num" == "60" && "$SKIP_LICENSE" == "1" ]]; then
    log "$desc"
    [[ "${BNK_REQUIRE_LICENSE}" == "true" ]] \
      && die "--skip-license refused, environment ${BNK_ENV_NAME} sets BNK_REQUIRE_LICENSE=true"
    warn "skipped by --skip-license"; continue
  fi
  log "$desc"
  # shellcheck disable=SC1090
  source "$HERE/lib/${id}.sh"
done

log "Done  env=${BNK_ENV_NAME} profile=${PROFILE}"
