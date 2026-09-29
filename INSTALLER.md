# Automated BIG-IP Next for Kubernetes installer

The official install guide is a long sequence of copy and paste steps. This replaces it with an
idempotent installer and a CI workflow, so a BNK cluster becomes something you can rebuild rather
than something you assembled once and hope never breaks.

Everything here was validated against a real Kubernetes 1.30 cluster with Calico, using the charts
pulled from `repo.f5.com`. It is not transcribed from the docs, it is what actually worked.

## Quick start

```bash
export FAR_PULL_JSON=/path/to/cne_pull_64.json
export BNK_LICENSE_JWT='eyJ...'          # omit and pass --skip-license to install unlicensed

./install.sh                             # host profile, full install
./install.sh --profile dpu               # BlueField DPU profile
./install.sh --dry-run --skip-license    # validate everything server side, change nothing
./install.sh --phase 70                  # run one phase, here just the verification
./uninstall.sh                           # remove BNK, leave cert-manager and Calico alone
```

## What it needs

A Kubernetes cluster you have admin on, with **Calico**, a default StorageClass, and outbound
access to `repo.f5.com`. `kubectl`, `helm` and `openssl` on the machine running it. Hugepages on
any node that will run TMM, because TMM uses DPDK.

## The five things that actually break this install

These are the reasons a hand run of the guide fails, and each one is handled in the code.

**1. FLO will not start without the Multus CRD.** Even for a host install that uses no network
attachments. It crash loops with `if kind is a CRD, it should be installed before calling Start`
on `NetworkAttachmentDefinition.k8s.cni.cncf.io`. The docs do not mention this. Phase 10 installs
Multus before phase 30 installs FLO, and phase 30 bounces FLO if it finds it restarting, so the
ordering is self healing.

**2. Two versions are not published, they are discovered.** The guide tells you to grep the FLO
and cert-gen versions out of the release manifest at install time, which makes every run
potentially different. They are resolved and pinned in `versions.env` as `v2.21.13-0.0.28` and
`0.9.3`, taken from release manifest `2.3.0-3.2598.3-0.0.170`.

**3. The CA CommonName must differ from the leaf CommonNames.** If it does not, CWC crash loops on
an x509 error that gives no hint about why. `CA_COMMON_NAME` in `versions.env` is deliberately
distinct, and phase 10 asserts `CA:TRUE` on the generated certificate rather than assuming it.

**4. Multus OOMKills under BNK.** BNK creates enough pods to flood Multus with CNI requests and the
default memory limit is not enough. Phase 10 raises it to 512Mi up front instead of leaving it as
a troubleshooting step.

**5. Connected mode licensing fails late.** The licence is validated against F5 at apply time, not
at install time, so a stale token gets you a fully built cluster that does nothing. Phase 60
reports the licence state explicitly and dumps the events if it does not reach `Active`.

## Phases

Each is a file in `lib/` and can be run alone with `--phase NN`.

| Phase | Does |
|---|---|
| 00 preflight | Tooling, cluster reachability, Kubernetes minor, CNI identification, Multus CRD, StorageClass, hugepages. Fails fast. |
| 10 prereqs | Multus, cert-manager, the three object CA chain with a `CA:TRUE` assertion. |
| 20 registry | Helm OCI login, both namespaces, the pull secret in each. |
| 30 flo | The Lifecycle Operator, with a restart if it raced the CRDs. |
| 40 certs | CWC certs via the cert-gen chart, OTEL certs as cert-manager Certificates. |
| 50 cneinstance | Renders a profile and applies it, then waits for the stack. |
| 60 license | Applies the License CR and reports whether it reaches Active. |
| 70 verify | Assertions replacing the guide's "Expect:" lines. Non zero exit on failure. |

## Profiles

`profiles/host.yaml` is BNK on Host. TMM runs as a software pod on host CPU with no scalable
functions, no SR-IOV, no VFIO and no NetworkAttachmentDefinitions. That is not a cut down
configuration, it is what the product supports. The `f5-tmm` chart ships `network.attachment`
empty and `vfio.enabled: false`, and the CNEInstance CRD requires only `certificate`,
`deploymentSize`, `manifestVersion`, `product` and `registry`.

`profiles/dpu.yaml` is BNK on DPU, with `dpu.enabled`, the two scalable function attachments,
9000 MTU and `ZEBOS_STATE: legacy`. It assumes the node work is already done, meaning DOCA, a
flashed BlueField, scalable functions with trust on, OVS bridges and hugepages. That part is node
provisioning and belongs in Ansible rather than here.

Override per environment with `BNK_STORAGECLASS` and `BNK_POD_CIDR`.

## CI

`.github/workflows/bnk-install.yml` has three jobs.

**lint** runs shellcheck, parses the profiles as YAML with placeholders substituted, and fails if
any version in `versions.env` is floating rather than pinned.

**e2e** builds a throwaway Kubernetes 1.30 cluster with Calico, allocates hugepages, installs BNK
unlicensed, then **runs the installer a second time** to prove idempotency. This is what stops the
installer rotting.

**deploy** is manual only. It writes a kubeconfig from a secret, does a server side dry run first,
then installs for real with a licence.

Repository secrets:

| Secret | Used by | What |
|---|---|---|
| `FAR_PULL_B64` | e2e, deploy | The contents of `cne_pull_64.json`. It is already base64, paste as is. |
| `BNK_LICENSE_JWT` | deploy | The licence token. |
| `KUBECONFIG_B64` | deploy | Base64 of a kubeconfig for the target cluster. |

No secret is ever committed. `install.sh` reads them from the environment only.

## What this does not do

Node provisioning. DOCA installs, BlueField flashing, scalable functions, OVS bridges, GRUB
hugepages and `kubeadm` are imperative, need reboots, and are not Kubernetes. They belong in
Ansible run before this. This installer starts from a working cluster and goes no lower.

## Validation status

Run against a real Kubernetes 1.30 cluster with Calico on 2026-09-29, host profile, unlicensed.

| Stage | Result |
|---|---|
| Preflight | passed, correctly warned that the node had no hugepages |
| Multus, cert-manager, CA chain | passed, `CA:TRUE` asserted |
| Registry, namespaces, pull secrets | passed |
| FLO `v2.21.13-0.0.28` | running, 22 F5 CRDs registered |
| CWC and OTEL certs | applied |
| CNEInstance, host profile | applied, 9 of 9 pods running in `f5-bnk`, 10 in `f5-cne-core` |
| Second full run | idempotent, every phase detected existing state |
| All 8 env x profile combinations | validated server side, rendered objects differ correctly |
| Verification | passed, no crash loops, no image pull failures |

Not reached on that box: `F5TmmAvailable` stayed Pending because the node had no hugepages, so the
TMM pod could not be scheduled against its `hugepages-2Mi` request. The `f5tmm` resource was
created correctly. This is the documented prerequisite, not an installer fault, and the preflight
flags it before anything else runs.

## Environments and profiles are independent

Two axes. The **environment** decides policy: sizing, storage, strictness, timeouts, whether a
licence is required. The **profile** decides the deployment model: DPU on or off, MTU, network
attachments. **Every environment runs either profile**, because a production site may be software
only on host or fitted with BlueField.

```bash
./install.sh --list-env --list-profile
./install.sh --env production --profile host    # software only production site
./install.sh --env production --profile dpu     # BlueField production site
./install.sh --env lab --profile dpu            # DPU bring up, lab policy
./install.sh --env demo                         # uses the environment's default profile
```

Configuration layers, later wins:

```
versions.env                       pinned component versions, shared by everything
environments/<env>.env             policy: size, storage, strictness, timeouts, licence
profiles/<profile>.env             model: dpu on/off, MTU, attachments, zebos
environments/<env>.<profile>.env   optional, only combinations that genuinely differ
```

That last file is why `production.host.env` exists. Jumbo frames are a DPU fabric thing, so a host
profile production site keeps MTU 1500 rather than inheriting 9000.

### Environment policy

| | lab | demo | staging | production |
|---|---|---|---|---|
| Default profile | host | host | dpu | dpu |
| Size | Small | Medium | Large | Large |
| Storage class | standard | standard | nfs | nfs |
| Core collection | off | off | on | on |
| Licence required | no | yes | yes | yes |
| Warnings fatal | no | no | no | **yes** |
| Wait timeout | 600s | 900s | 1800s | 2400s |

### Profile model

| | host | dpu |
|---|---|---|
| `dpu.enabled` | false | true |
| TMM MTU | 1500 | 9000 |
| Network attachments | none | `sf-external`, `sf-internal` |
| Dynamic routing | off | on |
| `ZEBOS_STATE` | unset | legacy |
| Needs SR-IOV | no | yes, `nvidia.com/bf3_*` |
| Needs hugepages | yes | yes |

Preflight adapts to the profile. On `dpu` it additionally checks that a node advertises
`nvidia.com/bf3_*` resources and that each NetworkAttachmentDefinition exists, and points you at
`dpubnkctl` if the nodes were never provisioned.

Two guardrails matter in practice. `BNK_REQUIRE_LICENSE=true` makes `--skip-license` an error, so
nobody accidentally ships an unlicensed demo. `BNK_STRICT_PREFLIGHT=true` in production turns every
warning into a failure, so a missing StorageClass or absent hugepages stops the run instead of
producing a cluster that half works.

## Operating it from GitHub

`.github/workflows/bnk-promote.yml` is the operational entry point. Choose an environment and an
action of plan, apply, verify or uninstall. A **plan always runs first**, as a server side dry run,
even when you asked for apply. Approvals come from GitHub Environments, so staging and production
require a reviewer while lab and demo do not, and each environment carries its own kubeconfig,
pull credentials and licence.

It also runs on a daily schedule against staging and production as a **drift check**, executing
phase 70 only. That means you find out that a cluster has degraded from a scheduled run rather
than from a customer.

Credentials are written to `RUNNER_TEMP`, never the workspace, and removed in an `always()` step.

## Known constraint, hugepages are mandatory

TMM requests `hugepages-2Mi` and the operator keeps that request even when you override
`advanced.tmm.resources` on the CNEInstance to remove it. So a node that will run TMM must have
hugepages allocated, which needs root on that node:

```bash
sudo sysctl -w vm.nr_hugepages=2048          # runtime, no reboot
echo 'vm.nr_hugepages = 2048' | sudo tee /etc/sysctl.d/90-bnk-hugepages.conf   # persist
```

Everything else in BNK comes up without them. On a cluster with no hugepages you will get all of
CWC, DSSM, RabbitMQ, IPAM, Observer, OTEL, AFM and the controllers running, with `F5TmmAvailable`
Pending and the `f5tmm` resource created but unscheduled. Preflight warns about this before
anything else runs, and in production it is fatal.
