#!/usr/bin/env bash
# The lint gate. CI runs exactly this, so running it locally gives the same answer.
#
# Keeping it in one file matters: when the local command and the CI command differ, a suppression
# added locally hides a finding that CI will fail on later.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# shellcheck disable=SC1091
source "$HERE/versions.env"

fail=0
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[0;32mok\033[0m  %s\n' "$1"; }
bad()  { printf '    \033[0;31mXX\033[0m  %s\n' "$1"; fail=$((fail+1)); }

step "shellcheck"
have="v$(shellcheck --version | awk '/^version:/{print $2}')"
if [[ "$have" != "${SHELLCHECK_VERSION}" ]]; then
  printf '    \033[0;33m!!\033[0m  shellcheck %s, pinned is %s. Findings can differ between versions,\n' "$have" "$SHELLCHECK_VERSION"
  printf '        so CI may disagree with this run. Install the pinned one to be sure.\n'
fi
# Only two suppressions, both justified. SC1090/SC1091 because lib/*.sh are sourced at runtime and
# SC2034/SC2154/SC2148 because they are fragments that inherit their variables from install.sh.
if shellcheck -s bash -e SC1090,SC1091 \
     install.sh uninstall.sh bootstrap/*.sh dpubnkctl/*.sh dpubnkctl/post-scripts/*.sh tests/*.sh; then
  ok "standalone scripts"
else bad "standalone scripts"; fi
if shellcheck -s bash -e SC1090,SC1091,SC2034,SC2154,SC2148 lib/*.sh; then
  ok "sourced phase libraries"
else bad "sourced phase libraries"; fi

step "bash syntax"
for f in install.sh uninstall.sh bootstrap/*.sh dpubnkctl/*.sh dpubnkctl/post-scripts/*.sh lib/*.sh tests/*.sh; do
  bash -n "$f" || bad "syntax $f"
done
ok "all scripts parse"

step "python"
if python3 -m py_compile .github/scripts/plan_clusters.py; then ok "plan_clusters.py compiles"
else bad "plan_clusters.py"; fi

step "pinned versions"
if grep -E '^[A-Z_]+=' versions.env | grep -iqE '=(latest|main|master)$'; then
  bad "a floating version in versions.env"; grep -inE '=(latest|main|master)$' versions.env
else ok "every version pinned"; fi

step "no committed credentials"
if grep -rInE '(eyJ[A-Za-z0-9_-]{30,}|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY)' . \
     --exclude-dir=.git --exclude-dir=node_modules >/dev/null 2>&1; then
  bad "something credential shaped is committed"
else ok "nothing credential shaped committed"; fi

printf '\n'
if [[ "$fail" -gt 0 ]]; then printf '  \033[0;31m%s check(s) failed\033[0m\n' "$fail"; exit 1; fi
printf '  \033[0;32mlint clean\033[0m\n'
