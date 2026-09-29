# clusters

One file per BNK cluster. This is the inventory the dispatcher fans out over, so adding a cluster
is a pull request rather than a conversation.

## Two runner topologies, pick per cluster

**`runner: beside`** puts a self hosted runner on the cluster's own host. The runner already has
kubectl access, so no kubeconfig is stored anywhere. Best for production and for anything behind a
firewall, because nothing reaches inbound.

**`runner: hub`** uses one runner that holds kubeconfigs for many clusters and selects a context per
target. Fewer runners to maintain, and it works for clusters you cannot put a runner on, but the hub
becomes a single point that can reach every cluster. Give it the treatment that implies.

You can mix both in one fleet. The dispatcher reads `runner` from each file and addresses
accordingly.
