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
# Pass --no-service on a host where you cannot sudo, such as a developer box. The runner then runs
# in the background rather than as a systemd unit, and does not survive a reboot.
#
#   GH_RUNNER_TOKEN=... ./install-runner.sh \
#     --repo OWNER/REPO --label prod-eu-west-1 --env production --profile dpu
#
# The label is how workflows address this host, matching the fleet/runners.yaml entry.
#
# Get the token from: Settings, Actions, Runners, New self hosted runner. It is short lived.
# Or, with gh installed and authenticated:
#   GH_RUNNER_TOKEN=$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token)
set -euo pipefail

REPO=""; ENVNAME=""; PROFILE=""; RUNNER_LABEL=""; RUNNER_USER="${RUNNER_USER:-$USER}"
NO_SERVICE=0
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-2.330.0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --env) ENVNAME="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --label) RUNNER_LABEL="$2"; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
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
# Installing packages needs root. With --no-service we assume the host is already equipped, which
# is the case on a developer box and on anything where you cannot sudo.
if [[ "$NO_SERVICE" == "0" ]]; then
  sudo apt-get update -qq
  sudo apt-get install -y curl jq git openssl
else
  for c in curl jq git openssl; do command -v "$c" >/dev/null || die "$c missing and --no-service cannot install it"; done
fi
command -v kubectl >/dev/null || die "kubectl not on PATH. The runner manages this cluster, so it needs it."
command -v helm >/dev/null || die "helm not on PATH. Install it before registering the runner."
if [[ "$PROFILE" == "dpu" ]]; then
  if [[ "$NO_SERVICE" == "0" ]]; then sudo apt-get install -y sshpass; else command -v sshpass >/dev/null || die "sshpass missing"; fi
  command -v yq >/dev/null || die "yq not on PATH, the dpubnkctl wizard post-script needs it"
fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "this host cannot reach a cluster. Fix kubectl first."
echo "    cluster reachable: $(kubectl config current-context)"

echo "### runner ${RUNNER_VERSION} into ${RUNNER_DIR}"
if [[ "$NO_SERVICE" == "1" ]]; then
  mkdir -p "$RUNNER_DIR" || die "cannot create $RUNNER_DIR. With --no-service, pass --dir to somewhere you own."
else
  sudo mkdir -p "$RUNNER_DIR"
  sudo chown "$RUNNER_USER" "$RUNNER_DIR"
fi
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

if [[ "$NO_SERVICE" == "1" ]]; then
  echo "### starting the runner in the background, no systemd"
  # Useful for a developer box or any host where you cannot sudo. It does not survive a reboot.
  nohup ./run.sh > "${RUNNER_DIR}/runner.log" 2>&1 &
  sleep 8
  grep -E 'Listening for Jobs|Connected to GitHub' "${RUNNER_DIR}/runner.log" | tail -2 \
    || { echo "runner did not report ready, see ${RUNNER_DIR}/runner.log"; tail -15 "${RUNNER_DIR}/runner.log"; exit 1; }
else
  echo "### systemd service so it survives reboots"
  sudo ./svc.sh install "$RUNNER_USER"
  sudo ./svc.sh start
  sleep 3
  sudo ./svc.sh status | head -5
fi

if [[ "$NO_SERVICE" == "1" ]]; then
  stop_hint="pkill -f '${RUNNER_DIR}/bin/Runner.Listener'"
else
  stop_hint="sudo ./svc.sh stop && sudo ./svc.sh uninstall"
fi

cat <<DONE

Runner registered with labels: ${LABELS}

Workflows address it with:
  runs-on: [self-hosted, bnk, "${RUNNER_LABEL}"]

Add it to fleet/runners.yaml so the fleet is documented in git.

Note what this buys you. The runner already holds cluster access, so KUBECONFIG_B64 is not needed
as a repository secret for this environment. You still need FAR_PULL_B64 and BNK_LICENSE_JWT,
because those are F5 credentials rather than cluster ones.

To remove it later:
  cd ${RUNNER_DIR}
  ${stop_hint}
  ./config.sh remove --token <a fresh registration token>
DONE
