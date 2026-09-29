#!/usr/bin/env bash
# Git driven wrapper around F5's dpubnkctl.
#
# F5's procedure is a sequence of commands you type on a jumphost, with four manual blocks in the
# middle. This wraps it so a deployment is one command plus a site file in git, and the manual
# blocks become the post-scripts dpubnkctl already hooks.
#
# Usage:
#   ./run.sh --site tokyo                 full deploy
#   ./run.sh --site tokyo --stage wizard  stop after discovery and the poc.yaml corrections
#   ./run.sh --site tokyo --verify        just re-run the verification
#   ./run.sh --site tokyo --destroy       tear the PoC down
#
# Expects on the jumphost: dpubnkctl binary, docker, yq, sshpass, and skopeo for online mode.
# Expects secrets out of band, never in git:
#   keys/f5-far-auth-key.tgz   FAR auth key from F5
#   keys/.jwt                  licence token
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE=""; STAGE="all"; DESTROY=0; VERIFY_ONLY=0
BIN="${DPUBNKCTL_BIN:-$HERE/bin/dpubnkctl}"
KEYS_DIR="${DPUBNKCTL_KEYS:-$HERE/keys}"
WORK="${DPUBNKCTL_WORK:-$HOME/dpubnkctl-work}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --destroy) DESTROY=1; shift ;;
    --verify) VERIFY_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32mok\033[0m  %s\n' "$*"; }
die()  { printf '    \033[0;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }

[[ -n "$SITE" ]] || die "pass --site <name>, see env/"
SITE_ENV="$HERE/env/${SITE}.env"
[[ -r "$SITE_ENV" ]] || die "no site file at $SITE_ENV"
# shellcheck disable=SC1090
source "$SITE_ENV"
export SITE_ENV

POC_DIR="${WORK}/${POC_NAME}"
export POC_DIR

log "Preflight"
[[ -x "$BIN" ]] || die "dpubnkctl not executable at $BIN. Build it and drop it in bin/, or set DPUBNKCTL_BIN."
for c in docker yq ssh; do command -v "$c" >/dev/null || die "$c not on PATH"; done
[[ "$AIRGAP_MODE" == "offline" ]] || command -v skopeo >/dev/null || die "skopeo needed for online mode"
command -v sshpass >/dev/null || die "sshpass needed by the provision post-script"
[[ -r "${KEYS_DIR}/f5-far-auth-key.tgz" ]] || die "missing ${KEYS_DIR}/f5-far-auth-key.tgz"
[[ -r "${KEYS_DIR}/.jwt" ]] || die "missing ${KEYS_DIR}/.jwt"
ok "site ${SITE}, poc ${POC_NAME}, mode ${AIRGAP_MODE}"

if [[ "$DESTROY" == "1" ]]; then
  log "Destroying ${POC_NAME}"
  cd "$WORK"
  "$BIN" destroy --yolo --confirm-cluster "$POC_NAME" --poc "$POC_NAME"
  ok "destroyed"
  exit 0
fi

if [[ "$VERIFY_ONLY" == "1" ]]; then
  log "Verify"
  exec "$HERE/verify.sh"
fi

log "Init"
mkdir -p "$WORK"; cd "$WORK"
if [[ -d "$POC_DIR" ]]; then
  ok "poc directory exists, reusing it"
else
  "$BIN" init "$POC_NAME" --customer "$CUSTOMER_NAME"
  ok "initialised"
fi

log "Staging keys and post-scripts"
install -m 600 "${KEYS_DIR}/f5-far-auth-key.tgz" "${POC_DIR}/keys/"
install -m 600 "${KEYS_DIR}/.jwt" "${POC_DIR}/keys/.jwt"
mkdir -p "${POC_DIR}/post-scripts"
install -m 755 "$HERE"/post-scripts/*.sh "${POC_DIR}/post-scripts/"
# the post-scripts read the site file, so make it reachable from where dpubnkctl runs them
ln -sfn "$SITE_ENV" "${POC_DIR}/post-scripts/site.env"
ok "keys and $(ls -1 "$HERE"/post-scripts/*.sh | wc -l) post-scripts staged"

log "Discovery wizard"
"$BIN" discover wizard --poc "$POC_NAME"
ok "poc.yaml generated and corrected by wizard.sh"
[[ "$STAGE" == "wizard" ]] && { ok "stopping at --stage wizard"; exit 0; }

if [[ "$AIRGAP_MODE" == "offline" ]]; then
  [[ -d "${DPUBNKCTL_ARTIFACTS:-}" ]] || die "offline mode needs DPUBNKCTL_ARTIFACTS pointing at an artifacts backup"
  log "Restoring artifacts for offline mode"
  cp -r "${DPUBNKCTL_ARTIFACTS}/." "${POC_DIR}/artifacts/"
  "$BIN" airgap verify --poc "$POC_NAME" || die "artifact staging incomplete"
  ok "artifacts restored and verified"
fi

log "End to end deploy, mode ${AIRGAP_MODE}"
"$BIN" e2e --yolo --airgap "$AIRGAP_MODE" --poc "$POC_NAME"

log "Verify"
"$HERE/verify.sh"

log "Backing up artifacts for future offline runs"
rm -rf "${WORK}/artifacts-backup-${POC_NAME}"
cp -r "${POC_DIR}/artifacts" "${WORK}/artifacts-backup-${POC_NAME}"
ok "artifacts backed up to ${WORK}/artifacts-backup-${POC_NAME}"
