#!/usr/bin/env bash
# Install a GitHub Actions self hosted runner on a BNK host.
#
# Why on the host rather than a cloud runner: the runner already has kubectl access to the
# cluster it manages, so no kubeconfig ever leaves the machine and no cluster credential is
# stored as a repository secret. For the DPU path it also already has SSH reach to the DPU.
#
# Run once per host, as a user with sudo. The runner then survives reboots as a systemd service.
#
# Usage:
#   GH_RUNNER_TOKEN=... ./install-runner.sh \
#     --repo iracic82/bnk-deploy --label tokyo-dpu-1 --env production --profile dpu
#
# The label is how workflows address this host, matching the fleet/runners.yaml entry.
#
# Get the token from: Settings, Actions, Runners, New self hosted runner. It is short lived.
# Or, with gh installed and authenticated:
#   GH_RUNNER_TOKEN=$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token)
set -euo pipefail

REPO=""; ENVNAME=""; PROFILE=""; RUNNER_LABEL=""; RUNNER_USER="${RUNNER_USER:-$USER}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-2.330.0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --env) ENVNAME="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --label) RUNNER_LABEL="$2"; shift 2 ;;
    --dir) RUNNER_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
[[ -n "$REPO" ]] || die "pass --repo OWNER/NAME"
[[ -n "$ENVNAME" ]] || die "pass --env lab|demo|staging|production"
[[ -n "$PROFILE" ]] || die "pass --profile host|dpu"
RUNNER_LABEL="${RUNNER_LABEL:-$(hostname -s)}"
[[ -n "${GH_RUNNER_TOKEN:-}" ]] || die "set GH_RUNNER_TOKEN, see the header for how to get one"

# The labels are how workflows find this machine. A workflow that must run where the cluster is
# targets runs-on: [self-hosted, bnk, production, dpu].
LABELS="bnk,${RUNNER_LABEL},${ENVNAME},${PROFILE}"

echo "### prerequisites the workflows expect on the host"
sudo apt-get update -qq
sudo apt-get install -y curl jq git openssl
command -v kubectl >/dev/null || die "kubectl not on PATH. The runner manages this cluster, so it needs it."
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
if [[ "$PROFILE" == "dpu" ]]; then
  sudo apt-get install -y sshpass
  command -v yq >/dev/null || die "yq not on PATH, the dpubnkctl wizard post-script needs it"
fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "this host cannot reach a cluster. Fix kubectl first."
echo "    cluster reachable: $(kubectl config current-context)"

echo "### runner ${RUNNER_VERSION} into ${RUNNER_DIR}"
sudo mkdir -p "$RUNNER_DIR"
sudo chown "$RUNNER_USER" "$RUNNER_DIR"
cd "$RUNNER_DIR"
if [[ ! -x ./config.sh ]]; then
  curl -fsSLo runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf runner.tar.gz && rm -f runner.tar.gz
fi

if [[ -f .runner ]]; then
  echo "    already configured, reusing registration"
else
  ./config.sh --unattended --replace \
    --url "https://github.com/${REPO}" \
    --token "$GH_RUNNER_TOKEN" \
    --name "bnk-${RUNNER_LABEL}" \
    --labels "$LABELS" \
    --work _work
fi

echo "### systemd service so it survives reboots"
sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start
sleep 3
sudo ./svc.sh status | head -5

cat <<DONE

Runner registered with labels: ${LABELS}

Workflows address it with:
  runs-on: [self-hosted, bnk, "${RUNNER_LABEL}"]

Add it to fleet/runners.yaml so the fleet is documented in git.

Note what this buys you. The runner already holds cluster access, so KUBECONFIG_B64 is not needed
as a repository secret for this environment. You still need FAR_PULL_B64 and BNK_LICENSE_JWT,
because those are F5 credentials rather than cluster ones.

To remove it later:
  cd ${RUNNER_DIR} && sudo ./svc.sh stop && sudo ./svc.sh uninstall && ./config.sh remove --token <fresh token>
DONE
