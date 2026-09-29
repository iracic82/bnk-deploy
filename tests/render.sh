#!/usr/bin/env bash
# Print the CNEInstance that install.sh would apply, for one environment and profile.
# CI uses this to prove every combination renders to valid yaml with no placeholder left behind.
#
#   ./tests/render.sh production dpu
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_name="${1:?pass an environment}"; profile="${2:?pass a profile}"

# shellcheck disable=SC1091
source "$HERE/versions.env"
# shellcheck disable=SC1090
source "$HERE/environments/${env_name}.env"
# shellcheck disable=SC1090
source "$HERE/profiles/${profile}.env"
combo="$HERE/environments/${env_name}.${profile}.env"
# shellcheck disable=SC1090
[[ -r "$combo" ]] && source "$combo"

# no cluster here, so use whatever the environment asked for
_render_sc="${BNK_STORAGECLASS:-standard}"
# shellcheck disable=SC1091
source "$HERE/lib/render.sh"
render_cneinstance "$HERE/profiles/${profile}.yaml"
