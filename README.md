# bnk-deploy

**Install and operate F5 BIG-IP Next for Kubernetes across a fleet of clusters, from git.**

Built for teams running AI infrastructure at more than one site. If you operate GPU capacity across
several clusters, regions or tenants, installing BNK by following a procedure on each one does not
scale and does not stay consistent. This makes it declarative, repeatable and reviewable.

```mermaid
flowchart LR
    G["<b>git</b><br/>clusters/*.yaml<br/>environments · profiles<br/>pinned versions"]
    W["<b>GitHub Actions</b><br/>plan · approve · apply"]
    R["<b>runners</b><br/>beside each cluster<br/>or one hub"]
    C1["cluster<br/>eu-west"]
    C2["cluster<br/>us-east"]
    C3["cluster<br/>ap-south"]
    G --> W --> R
    R --> C1
    R --> C2
    R --> C3
    style G stroke-width:2px
    style R stroke-width:2px
```

---

## What you get

**One command per cluster, or one run for the whole fleet.** `./install.sh --env production
--profile dpu` for a single cluster, or a dispatch that fans out across everything matching a
selector.

**Both BNK deployment models.** Host mode where TMM runs as a software pod, and DPU mode where it
runs on NVIDIA BlueField with DOCA offload. Every environment supports either, because a production
site may be software only or fitted with BlueField.

**Bare metal from nothing, too.** If you do not have a cluster yet, the DPU path wraps F5's own
`dpubnkctl` to flash BlueField cards, provision nodes, build the cluster and install BNK.

**Safe by default.** Every apply plans first. Applying across more than one cluster needs an
explicit opt in. Production makes every preflight warning fatal. Nothing installs on a merge.

**It knows the traps.** Five failure modes that are not in the official install guide are handled
before they bite you. They are listed further down, with what each one costs if you hit it blind.

**Pinned and reproducible.** Every component version is fixed in one file, including two that F5's
procedure has you discover at install time.

---

## Before you start

A checklist for the platform team. Work top to bottom and you will not get stopped halfway.

### 1. Get two things from F5

| | What it is | Where it goes |
|---|---|---|
| `cne_pull_64.json` | Registry credential for `repo.f5.com`. A base64 wrapped service account key | `FAR_PULL_JSON` locally, `FAR_PULL_B64` as a GitHub secret |
| Licence token | A JWT. Ask for the deployment mode you need, connected or disconnected | `BNK_LICENSE_JWT` |

Check the licence is **current** before you plan any work around it. It is validated against F5 at
apply time, not at install time, so an expired token hands you a fully built control plane with no
data plane and no obvious reason why.

### 2. Make sure each cluster qualifies

| | Requirement | Why it matters |
|---|---|---|
| Kubernetes | **1.30** | The version BNK 2.3 is qualified against |
| CNI | **Calico** | The primary supported CNI. Flannel, VPC-CNI on EKS, OCI-CNI on Oracle and OVN-Kubernetes on OpenShift are recognised. **Cilium is not supported** and the operator will refuse it |
| Hugepages | allocated on every node that will run TMM | TMM uses DPDK. Without them TMM is never scheduled, and no override removes the requirement |
| TMM node label | `kubectl label node <NODE> app=f5-tmm` on at least one node | **Easy to miss and gives a terrible error.** Without it the operator panics with `assignment to entry in nil map` at `f5tmm_daemonset.go:186`, naming neither TMM nor the label. Preflight checks it |
| CPU | roughly **17 vCPU of requests** across the cluster | Measured at `deploymentSize: Small`: about 8.4 vCPU requested in `f5-cne-core` and the same again in `f5-bnk`. Pods sit Pending with `Insufficient cpu` if the cluster cannot satisfy it |
| Storage | a default StorageClass | The datastore components need persistent volumes |
| Egress | outbound to `repo.f5.com` | 81 component images are pulled from there |
| Tooling | `kubectl`, `helm`, `openssl` | On whatever runs the installer |

Allocating hugepages, which needs root on the node:

```bash
sudo sysctl -w vm.nr_hugepages=2048                                   # 4Gi, takes effect now
echo 'vm.nr_hugepages = 2048' | sudo tee /etc/sysctl.d/90-bnk.conf    # persist it
```

If a node was already running when you set this, kubelet has to rediscover the capacity before the
scheduler will believe it. Restart kubelet on that node, then confirm with
`kubectl get node <node> -o jsonpath='{.status.allocatable.hugepages-2Mi}'`.

### 3. Decide DPU or host per cluster

**Host mode** runs TMM as a software pod on host CPU. No BlueField, no scalable functions, no
SR-IOV, no Multus attachments. Anything that meets the table above can run it.

**DPU mode** runs TMM on NVIDIA BlueField-3 with DOCA offload. It additionally needs the cards
fitted, the SR-IOV device plugin advertising scalable functions, OVS bridges configured on the DPU
and hugepages on it. If that node level work is not done, use the bare metal path which does all of
it for you.

You do not have to choose the same mode everywhere. Any environment runs either.

### 4. Decide where the runners go

One runner per cluster on its own host means **nothing reaches inbound into your network** and no
kubeconfig is stored anywhere. One shared hub runner holding a merged kubeconfig means fewer runners
to maintain but a host that can reach every cluster. Both are supported and you can mix them.

### 5. Set it up once, then work through pull requests

```
register a runner  ->  create the GitHub environments  ->  open a PR adding your cluster
```

After that, nobody runs the installer by hand. A pull request is how a cluster is added, changed or
rebuilt.

```mermaid
flowchart LR
    PR["<b>pull request</b><br/>add or edit<br/>clusters/&lt;name&gt;.yaml"]
    P["<b>plan</b><br/>dry run on that<br/>cluster's own runner"]
    REV["plan posted as a<br/>PR comment, reviewed<br/>beside the diff"]
    M["<b>merge</b>"]
    A["<b>apply</b><br/>only the clusters<br/>the merge touched"]
    G{"environment needs<br/>a reviewer?"}
    W["waits for approval"]
    C["cluster installed<br/>or updated"]

    PR --> P --> REV --> M --> A --> G
    G -->|"lab, demo"| C
    G -->|"staging, production"| W --> C

    style PR stroke-width:2px
    style C stroke-width:2px
```

Three properties worth knowing.

Only the clusters a change **touched** are acted on, so editing one cluster never disturbs another,
and editing the installer itself triggers no installs at all.

Approval is a **GitHub Environment setting**, not a manual step. A merge affecting a production
cluster queues the job and waits for a human, while lab and demo proceed unattended. You configure
that once.

A **version bump installs nothing.** Changing `versions.env` does not touch `clusters/`, so nothing
fans out by surprise. Roll it out deliberately with `dispatch` when you are ready.

---

## Quick start, one cluster

```bash
git clone https://github.com/iracic82/bnk-deploy.git && cd bnk-deploy

export FAR_PULL_JSON=/path/to/cne_pull_64.json      # your F5 registry credential
export BNK_LICENSE_JWT='eyJ...'                     # your F5 licence token

./install.sh --env lab --profile host --dry-run     # validate, change nothing
./install.sh --env lab --profile host               # install
./install.sh --env lab --phase 70                   # verify only
./uninstall.sh                                      # remove BNK, leave cert-manager and Calico
```

Re-running is safe. Every phase detects what already exists, so a second run is a no op rather
than a second install.

### The eight phases

Each can be run alone with `--phase NN`, which is how you debug a partial install without
starting over.

| | |
|---|---|
| 00 preflight | Tooling, cluster reachability, Kubernetes version, CNI identification, Multus CRD, StorageClass, hugepages. Fails fast |
| 10 prereqs | Multus, cert-manager, and the three object certificate authority chain |
| 20 registry | Registry login, namespaces, image pull secrets |
| 30 flo | The F5 Lifecycle Operator, which reconciles everything after it |
| 40 certs | CWC and OpenTelemetry certificates |
| 50 cneinstance | The CNEInstance, then waits for the stack |
| 60 licence | Applies the licence and reports whether it activates |
| 70 verify | Assertions, non zero exit on failure |

---

## Two paths in

```mermaid
flowchart LR
    Q{"Working Kubernetes<br/>cluster with Calico?"}
    Q -->|yes| I["<b>./install.sh</b><br/>host or dpu profile<br/>any environment"]
    Q -->|"no, bare metal<br/>with BlueField DPUs"| B["<b>./dpubnkctl/run.sh</b><br/>flashes DPUs, provisions nodes,<br/>builds the cluster, installs BNK"]
    B -.->|"cluster now exists"| I
    style I stroke-width:2px
    style B stroke-width:2px
```

The bare metal path wraps F5's `dpubnkctl`. Its published procedure leaves four manual blocks in
the middle, configuring OVS bridges on the DPU, applying netplan on the host, and setting up
kubeconfig. Those become the post-scripts the tool already hooks, so the whole build is one
command. Every site specific value, interface names, addresses, bridge names and DPU count, lives
in `dpubnkctl/env/<site>.env` rather than in the scripts.

---

## Many clusters

Add a file to `clusters/` and the cluster is in the fleet. That is the whole onboarding step, so it
happens in a pull request rather than in someone's head.

The files shipped here are **examples and are all disabled**, so a fresh clone can target nothing
until you say otherwise. Copy one, rename it, fill in your values and set `enabled: true`.

```yaml
# clusters/prod-eu-west.yaml
name: prod-eu-west
description: Production inference cluster, BlueField fitted.

runner: beside                 # beside | hub
runner_label: prod-eu-west-1

environment: production        # lab | demo | staging | production
profile: dpu                   # host | dpu

kube_context: prod-eu-west
storage_class: nfs
pod_cidr: 192.168.0.0/16

enabled: true
```

```mermaid
flowchart TB
    INV["<b>clusters/*.yaml</b><br/>the inventory"]
    PLAN["<b>plan</b><br/>selector to matrix<br/>all · env:production · profile:dpu<br/>name:one · runner:hub"]
    GATE{"apply to more<br/>than one cluster?"}
    DEP["<b>deploy</b><br/>one job per cluster<br/>max-parallel 3, fail-fast off"]

    INV --> PLAN --> GATE
    GATE -->|"no, or fleet apply<br/>explicitly enabled"| DEP
    GATE -->|"yes and not enabled"| STOP["refused, plan only"]

    DEP --> R1["runner <b>beside</b><br/>on the cluster host<br/>no kubeconfig anywhere"]
    DEP --> R2["runner <b>hub</b><br/>one merged kubeconfig<br/>selected by context"]
    R1 --> C1["cluster A"]
    R2 --> C2["cluster B"]
    R2 --> C3["cluster C"]

    style INV stroke-width:2px
    style STOP stroke-dasharray: 5 4
```

Then from the Actions tab, run **dispatch**:

```
select: all              action: plan     # dry run every enabled cluster, always safe
select: env:production   action: apply    # needs BNK_FLEET_APPLY_ENABLED
select: name:prod-eu-west action: apply   # one cluster, no gate needed
select: profile:dpu      action: verify   # health check every DPU cluster
```

An apply touching more than one cluster is refused unless the repository variable
`BNK_FLEET_APPLY_ENABLED` is `true`, so the worst an accidental run can do is plan. One cluster
failing never stops the rest of the fleet, and parallelism is capped so a fleet run does not
saturate your runners or the registry.

### Where the runners go

**`runner: beside`** puts a self hosted runner on the cluster's own host. It already has kubectl
access, so no kubeconfig is stored anywhere and **nothing reaches inbound into your network**. This
is the right choice for production, for air gapped sites, and for anything behind a firewall.

**`runner: hub`** uses one runner holding a single merged kubeconfig with a context per cluster.
Fewer runners to maintain, and it reaches clusters that cannot host one. The trade is that the hub
can reach every cluster in its kubeconfig, so it deserves the same protection as a jump host.

Mix both in one fleet. Register a host with:

```bash
GH_RUNNER_TOKEN=$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token)

sudo -E ./bootstrap/install-runner.sh \
  --repo OWNER/REPO --label prod-eu-west-1 --env production --profile dpu
```

It refuses to register a host that cannot reach a cluster, installs what the workflows need, and
runs as a systemd service so it survives reboots.

---

## Environments and profiles

Two independent axes. The **environment** sets policy. The **profile** sets the deployment model.
Any environment runs either profile.

| | lab | demo | staging | production |
|---|---|---|---|---|
| Default profile | host | host | dpu | dpu |
| Deployment size | Small | Medium | Large | Large |
| Storage class | standard | standard | nfs | nfs |
| Core collection | off | off | on | on |
| Licence required | no | yes | yes | yes |
| Warnings fatal | no | no | no | **yes** |
| Wait timeout | 600s | 900s | 1800s | 2400s |

| | host | dpu |
|---|---|---|
| `dpu.enabled` | false | true |
| TMM MTU | 1500 | 9000 |
| Network attachments | none | `sf-external`, `sf-internal` |
| Dynamic routing | off | on |
| Needs SR-IOV | no | yes |

```mermaid
flowchart LR
    V["<b>versions.env</b><br/>pinned component versions<br/>shared by everything"]
    E["<b>environments/&lt;env&gt;.env</b><br/>policy<br/>size · storage · strictness<br/>timeouts · licence"]
    P["<b>profiles/&lt;profile&gt;.env</b><br/>deployment model<br/>dpu on/off · MTU · attachments"]
    C["<b>environments/&lt;env&gt;.&lt;profile&gt;.env</b><br/>optional<br/>only combinations that differ"]
    R["rendered<br/>CNEInstance"]
    V --> E --> P --> C --> R
    style R stroke-width:2px
```

Later layers win. The combination file exists for cases like a production site on host mode, where
jumbo frames are a DPU fabric concern and the MTU should stay at 1500 rather than inherit 9000.

Two guardrails are worth knowing. Outside lab, `--skip-license` is an error, so nobody ships an
unlicensed demo by accident. In production every preflight warning is fatal, so a missing
StorageClass stops the run instead of producing a cluster that half works.

---

## The five traps this handles for you

All were found by running the install, not by reading about it. Each one costs real time if you
meet it without warning.

```mermaid
flowchart TB
    NAD["Multus<br/>NetworkAttachmentDefinition CRD"]
    FLO["F5 Lifecycle Operator"]
    CNE["CNEInstance"]
    CP["Control plane<br/>CWC · DSSM · RabbitMQ · IPAM<br/>AFM · Observer · OTEL · CSRC"]
    TMM["TMM<br/>data plane"]
    LIC["License<br/>state Active"]

    NAD -->|"FLO crash loops without it,<br/>even for a host install<br/>that uses no attachments"| FLO
    FLO --> CNE
    CNE --> CP
    CNE --> TMM
    LIC -->|"the controller skips its<br/>resource controllers<br/>without a licence"| TMM

    style NAD stroke-width:2px
    style LIC stroke-width:2px
    style TMM stroke-dasharray: 5 4
```

**1. No node label, no data plane, and a stack trace instead of an explanation.** The host install
path requires `kubectl label node <NODE> app=f5-tmm`, and the docs say plainly that without it
nothing schedules TMM. What actually happens is that the Lifecycle Operator panics with
`assignment to entry in nil map` at `f5tmm_daemonset.go:186`, recovers, requeues and panics again
every few minutes, while every other component reports healthy. Verified on a real cluster: adding
the label moved `f5tmm` from `Reconciled=Unknown` to `Reconciled=True` and the DaemonSet appeared
in seconds. Preflight checks for the label, and also warns if a labelled node has no hugepages.

**6. The operator will not start without the Multus CRD.** Even for a host install that uses no
network attachments, the Lifecycle Operator crash loops on `if kind is a CRD, it should be
installed before calling Start`. Nothing in the install guide mentions this, and the error does not
point at Multus. Phase 10 installs Multus before phase 30 installs the operator, and phase 30
restarts the operator if it finds it looping, so the ordering is self healing.

**2. Two component versions are discovered, not published.** The procedure has you grep the
Lifecycle Operator and cert generation versions out of a release manifest at install time, which
makes every run potentially different. They are resolved and pinned in `versions.env`.

**3. The certificate authority CommonName must differ from the leaf CommonNames.** If it does not,
the licensing component crash loops on an x509 error that gives no hint why. The chain is built
correctly and the result is asserted to actually be a CA rather than assumed.

**4. Multus runs out of memory under BNK.** BNK creates enough pods to flood it with CNI requests
and the default limit is not enough. Raised up front rather than left as a troubleshooting step
after pods fail to start.

**5. An unlicensed install has no data plane, by design.** Without a licence the controller logs
`License is not enabled.. skip Resource controllers` and never creates TMM. The whole control plane
comes up and the data plane does not. Verification reports that as expected rather than as a fault,
so you are not left hunting a problem that is not there.

---

## Run summaries

Every workflow that installs or plans writes a summary, so clicking a run shows what happened
instead of raw logs: the cluster and context it touched, the environment and profile, whether it was
a plan or an apply, each phase with a tick or a warning, and the licence, CNEInstance and TMM state
afterwards.

The installer emits it itself rather than each workflow building its own, so they cannot disagree
and a new workflow gets one for free.

## Workflows

| Workflow | Trigger | Runs on | Does |
|---|---|---|---|
| `validate` | PR, push | hosted | shellcheck, actionlint, contract tests, renders every environment and profile combination, refuses floating versions, scans for committed credentials |
| `plan` | **PR** touching `clusters/**` | self hosted | dry runs each touched cluster, posts the plan as a PR comment |
| `apply` | **merge** to main touching `clusters/**` | self hosted | installs or updates each touched cluster. Approval comes from the GitHub Environment |
| `deploy` | called by `apply` and `dispatch` | self hosted | the single implementation. Plans then applies, or verifies, or uninstalls. Locked per cluster so two runs cannot race |
| `dispatch` | manual | hosted then self hosted | deliberate fleet wide work, such as rolling out a version bump. Applying to more than one cluster needs `BNK_FLEET_APPLY_ENABLED` |
| `cluster-check` | dispatch, daily | self hosted | verification only, drift detection |
| `e2e-kind` | PR, push | hosted | throwaway 1.30 cluster with Calico. Runs phases 00 to 40 plus a server side CNEInstance validation, twice, to prove idempotency. It cannot install the data plane, see below |
| `dpubnkctl-deploy` | dispatch | jumphost | bare metal DPU build |

`apply` and `dispatch` both call `deploy`, so there is one implementation of an install and no
second copy to drift. What differs is how the clusters are chosen: `apply` uses what the merge
touched, `dispatch` uses a selector you pick.

---

## Secrets

Nothing sensitive is committed, and CI fails the build if anything credential shaped appears.

| Secret | Used by | What it is |
|---|---|---|
| `FAR_PULL_B64` | all install paths | Your F5 registry credential, the contents of `cne_pull_64.json` |
| `BNK_LICENSE_JWT` | licensed installs | Your F5 licence token |
| `HUB_KUBECONFIGS` | hub runners only | One merged kubeconfig with a context per cluster |
| `FAR_AUTH_KEY_B64` | bare metal path | The FAR auth key, the format `dpubnkctl` expects |

Store them **per GitHub Environment** so staging and production credentials are separate and gated
by reviewers. Runners that sit beside their cluster need **no kubeconfig secret at all**.

One exception worth knowing. `e2e-kind` builds a throwaway cluster on a hosted runner and declares
no environment, so it can only read **repository** secrets. Set `FAR_PULL_B64` at repository level
as well if you want that regression test to run, otherwise it fails at the credentials step with
the secret empty. Everything that touches a real cluster reads environment secrets only.

---

## Validation status

Honest about what has and has not been proven, because a deployment tool that overstates its
testing is worse than one that says nothing.

**Verified** on a three node Kubernetes 1.30 cluster with Calico. Full install clean end to end,
the operator running with 22 custom resource definitions registered, the control plane distributed
across all three nodes with every container ready, and a second run a complete no op. All eight
environment and profile combinations validate server side and render correctly differing objects.
Both runner topologies exercised, including a context that does not exist failing rather than
silently operating on the wrong cluster.

**A licensed install is verified.** The licence reaches `Active` in connected mode, the operator
then creates the TMM DaemonSet, and TMM comes up with both readiness gates satisfied,
`ConfigurationDone` and `RoutingDone`. Final state on a three node cluster: `CNEInstance
Available=True`, `F5TmmAvailable=True`, TMM 1/1 ready, 13 pods in `f5-cne-core` and 10 in `f5-bnk`.

**DPU mode** is validated as far as rendering and preflight. The node level work, flashing and
scalable functions, needs real BlueField hardware to prove.

**Why `e2e-kind` stops short of a full install.** A GitHub hosted runner has 4 vCPU and BNK requests
around 17, so the pods sit Pending with `Insufficient cpu`. No configuration changes that. So it
covers the parts most likely to regress, meaning preflight, the Multus before FLO ordering, the
certificate authority chain, registry access, the pinned versions, and that a rendered CNEInstance
is accepted by a real API server. Installing the data plane is proven on a real cluster by the
`plan` and `apply` workflows instead.

---

## Keeping your inventory private

Your cluster inventory describes your topology, so think about where it lives before you put real
values in it.

**If this repo is private to your team**, commit your clusters straight into `clusters/`. That is
the design, and it is what makes an added cluster reviewable in a pull request.

**If you fork this publicly, or share it outward**, keep the shipped examples as documentation and
hold your real inventory somewhere private. Two workable shapes: keep a private fork that carries
your real `clusters/`, or add real files in a private overlay repo and point the planner at it. The
planner only reads `clusters/*.yaml`, so redirecting it is a one line change.

Nothing else in the repo contains topology. Addresses, interface names, bridge names and DPU counts
all live in `dpubnkctl/env/<site>.env`, which is gitignored by default.

## Scope

This installs and operates BNK on Kubernetes. It does not do node provisioning, meaning DOCA
installs, BlueField flashing, OVS bridges, kernel parameters and `kubeadm`, because those are
imperative, need reboots and are not Kubernetes. Use the bare metal path for that, or your own
configuration management. A cluster reconciler should not own a file on a node.
