# bnk-deploy

Automated deployment for F5 BIG-IP Next for Kubernetes.

Two supported paths, because BNK has two deployment models and they need different tooling. Pick
by what you already have, not by preference.

```
Do you already have a working Kubernetes cluster with Calico?
│
├── yes ──> ./install.sh        our installer, host or dpu profile
│                               phases, idempotent, CI tested on every commit
│
└── no, bare metal with BlueField DPUs
           └──> dpubnkctl  F5's dpubnkctl wrapped for git
                                  provisions nodes, flashes DPUs, builds the cluster, installs BNK
```

## install.sh, host and DPU profiles on an existing cluster

Our own installer. Starts from a working cluster and goes no lower. Eight phases, each runnable
alone, safe to re-run.

```bash
export FAR_PULL_JSON=/path/to/cne_pull_64.json
export BNK_LICENSE_JWT='eyJ...'
./install.sh --list-env             # lab, demo, staging, production
./install.sh --env lab --skip-license
./install.sh --env production       # dpu profile, strict preflight
```

Four environments ship with the installer and are selected with `--env`. lab and demo default to
the host profile, staging and production to dpu. Production makes every preflight warning fatal and
refuses to run unlicensed. The full matrix is in [INSTALLER.md](INSTALLER.md).

For day to day operations use the workflow rather than the shell. `bnk-promote.yml` takes an
environment and an action of plan, apply, verify or uninstall, always runs a server side plan
first, takes approvals from GitHub Environments, and runs a daily drift check against staging and
production.

**Host profile** needs no scalable functions, no SR-IOV, no VFIO and no
NetworkAttachmentDefinitions. That is not a reduced configuration. The `f5-tmm` chart ships
`network.attachment` empty with `vfio.enabled: false`, and the CNEInstance CRD requires only five
fields. Validated end to end on Kubernetes 1.30 with Calico.

**DPU profile** assumes the node work is done already, meaning DOCA, a flashed BlueField, scalable
functions with trust on, OVS bridges and hugepages. If that is not done, you want the other path.

CI proves this on every change by building a throwaway 1.30 cluster, installing BNK, then
installing it a second time to prove idempotency. See `.github/workflows/bnk-install.yml`.

## dpubnkctl, bare metal DPU from nothing

F5 ships `dpubnkctl`, a jumphost tool that does the whole thing including DPU flashing. Its
procedure is a sequence of typed commands with four manual blocks in the middle. This wraps it so
a deployment is one command plus a site file in git, and those manual blocks become the
post-scripts the tool already hooks.

```bash
cp dpubnkctl/env/example.env dpubnkctl/env/mysite.env   # edit, commit, no secrets
./dpubnkctl/run.sh --site mysite
```

| Post-script | Replaces |
|---|---|
| `wizard.sh` | Hand editing `poc.yaml` after discovery |
| `provision.sh` | The manual OVS bridge block on the DPU |
| `host-network.sh` | The manual netplan block on the host, plus a ping gate on both paths |
| `cluster-up.sh` | The manual kubeconfig block, and it stages a kubeconfig for CI |

Every site specific value, interfaces, addresses, bridge names, DPU count, lives in
`env/<site>.env`. Nothing in the scripts is lab specific, which is the point.

Supports both airgap modes. Online stages images on the jumphost with skopeo. Offline restores an
artifacts backup from a prior online run and verifies the staging before deploying.

`.github/workflows/dpubnkctl-deploy.yml` runs it from a self hosted runner on the jumphost, manual
dispatch, with wizard-only, deploy, verify and destroy actions.

## Secrets, in both paths

Never committed. `dpubnkctl/.gitignore` blocks `keys/`, `*.jwt` and real site files.

| Secret | Path | Used for |
|---|---|---|
| `cne_pull_64.json` | install.sh | Registry pull, a base64 wrapped GCP service account for the GAR behind `repo.f5.com` |
| `f5-far-auth-key.tgz` | dpubnkctl | FAR auth, the format dpubnkctl expects |
| Licence JWT | both | `operationMode: connected` validates against F5 live, so a stale token fails at apply time with a fully built cluster |

## Node provisioning is deliberately out of scope for install.sh

DOCA installs, BlueField flashing, scalable functions, OVS bridges, GRUB hugepages and `kubeadm`
are imperative, need reboots, and are not Kubernetes. Either let `dpubnkctl` do it or put it in
Ansible. Do not try to make a cluster reconciler own a file on a node.
