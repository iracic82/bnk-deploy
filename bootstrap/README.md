# bootstrap

Getting a host into the fleet.

## Why a runner on the host

The runner lives on the machine that owns the cluster. That means no kubeconfig is stored as a
repository secret, nothing reaches into your network from outside, and for the DPU path the runner
already has SSH reach to the DPU over tmfifo. The only secrets a workflow needs are F5
credentials, not cluster ones.

## Register a host

```bash
GH_RUNNER_TOKEN=$(gh api -X POST repos/iracic82/bnk-deploy/actions/runners/registration-token -q .token)

sudo -E ./install-runner.sh \
  --repo iracic82/bnk-deploy \
  --label tokyo-dpu-1 \
  --env production \
  --profile dpu
```

The label is how workflows address the host: `runs-on: [self-hosted, bnk, "tokyo-dpu-1"]`.

What it does. Installs `curl`, `jq`, `git`, `openssl`, and helm if absent. For the DPU profile also
`sshpass` and it insists on `yq`, because the dpubnkctl wizard post-script needs it. Refuses to
register if the host cannot reach a cluster, because a runner that cannot run kubectl is useless.
Installs the runner as a systemd service so it survives reboots.

## Then

Add the host to [`../fleet/runners.yaml`](../fleet/runners.yaml) so the fleet is documented in git
rather than only in the GitHub settings page. Optionally copy `site.yml` per site so the host facts
are reviewable in a pull request.

## Remove a host

```bash
cd /opt/actions-runner
sudo ./svc.sh stop && sudo ./svc.sh uninstall
./config.sh remove --token <fresh registration token>
```
