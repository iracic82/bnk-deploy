# Cluster prerequisites. Order matters: Multus before FLO, and the CA chain is three objects.
KA=(kubectl apply -f -)
[[ "$DRY_RUN" == "1" ]] && KA=(kubectl apply --dry-run=server -f -)

# --- Multus. Must come first, see the note in 00-preflight. ---
if kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1; then
  ok "Multus CRD already present"
else
  kubectl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml" >/dev/null
  ok "Multus ${MULTUS_VERSION} applied"
fi
if kubectl -n kube-system get ds kube-multus-ds >/dev/null 2>&1; then
  kubectl -n kube-system set resources ds kube-multus-ds -c kube-multus --limits=memory="${MULTUS_MEMORY_LIMIT}" >/dev/null
  ok "Multus memory limit ${MULTUS_MEMORY_LIMIT} (default OOMKills under BNK CNI load)"

  # The DPU path taints its nodes dpu=true:NoSchedule so only TMM and permitted system pods land
  # there. Multus is one of the permitted ones, so it needs the toleration or it never runs on the
  # DPU and TMM has no CNI. The docs patch it in the same way.
  if [[ "${BNK_DPU_ENABLED:-false}" == "true" && "$DRY_RUN" == "0" ]]; then
    if kubectl -n kube-system get ds kube-multus-ds \
         -o jsonpath='{.spec.template.spec.tolerations[*].key}' 2>/dev/null | grep -q dpu; then
      ok "Multus already tolerates the DPU taint"
    else
      kubectl -n kube-system patch ds kube-multus-ds --type=json -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"dpu","operator":"Equal","value":"true","effect":"NoSchedule"}}]' >/dev/null 2>&1 \
        || kubectl -n kube-system patch ds kube-multus-ds --type=json -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"dpu","operator":"Equal","value":"true","effect":"NoSchedule"}]}]' >/dev/null
      ok "Multus patched to tolerate dpu=true:NoSchedule"
    fi
  fi
fi

# --- cert-manager ---
if kubectl get deploy -n cert-manager cert-manager-webhook >/dev/null 2>&1; then
  ok "cert-manager already present"
else
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s >/dev/null
  ok "cert-manager ${CERT_MANAGER_VERSION} ready"
fi

# Deployment rollout complete is NOT the same as the webhook actually serving: for a few seconds the
# API server -> webhook call can still be refused (cert injection / endpoint routing lag), which
# intermittently failed the very next cert-manager apply (the ClusterIssuer below) with
# "connection refused". Probe the webhook with a server dry-run Issuer until it accepts a request.
for _ in $(seq 1 60); do
  kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'PROBE' && break
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: webhook-readiness-probe
  namespace: cert-manager
spec:
  selfSigned: {}
PROBE
  sleep 3
done
ok "cert-manager webhook is serving"

# --- CA chain. selfsigned issuer -> CA cert -> CA ClusterIssuer.
# The CA CommonName MUST differ from the leaf CNs or CWC crash loops on an x509 error.
"${KA[@]}" <<YAML >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: temp-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: f5-cne-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: ${CA_COMMON_NAME}
  secretName: f5-cne-ca-secret
  duration: 43800h
  privateKey: { algorithm: RSA, size: 4096, encoding: PKCS1 }
  issuerRef: { name: temp-selfsigned, kind: ClusterIssuer }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CLUSTER_ISSUER}
spec:
  ca:
    secretName: f5-cne-ca-secret
YAML
if [[ "$DRY_RUN" == "0" ]]; then
  kubectl wait --for=condition=Ready certificate/f5-cne-ca -n cert-manager --timeout=240s >/dev/null
  # verify CA:TRUE rather than trusting it
  kubectl get secret f5-cne-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -text | grep -q 'CA:TRUE' \
    || die "f5-cne-ca is not a CA certificate"
  ok "CA chain ready, CA:TRUE verified, issuer ${CLUSTER_ISSUER}"
fi

# --- SR-IOV device plugin, DPU profile only ---
if [[ "$PROFILE" == "dpu" ]]; then
  # The SR-IOV device plugin advertises the scalable functions to Kubernetes. Without it TMM cannot
  # request nvidia.com/bf3_* and never schedules. It is node level work, so we verify rather than
  # install it, and say exactly what is missing.
  if kubectl -n kube-system get ds kube-sriov-device-plugin >/dev/null 2>&1; then
    ok "SR-IOV device plugin present"
    if kubectl -n kube-system get ds kube-sriov-device-plugin \
         -o jsonpath='{.spec.template.spec.tolerations[*].key}' 2>/dev/null | grep -q dpu; then
      ok "SR-IOV device plugin tolerates the DPU taint"
    else
      warn "SR-IOV device plugin does not tolerate dpu=true:NoSchedule, so it will not run on a tainted DPU node"
    fi
  else
    warn "no SR-IOV device plugin. The DPU profile needs it to advertise scalable functions. Use dpubnkctl/run.sh if the nodes are not provisioned."
  fi
fi
