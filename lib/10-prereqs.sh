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
fi

# --- cert-manager ---
if kubectl get deploy -n cert-manager cert-manager-webhook >/dev/null 2>&1; then
  ok "cert-manager already present"
else
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s >/dev/null
  ok "cert-manager ${CERT_MANAGER_VERSION} ready"
fi

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
  warn "DPU profile: install the SR-IOV device plugin ${SRIOV_DP_VERSION} and its ConfigMap,"
  warn "and add a dpu=true:NoSchedule toleration. See profiles/dpu.yaml for the CNEInstance."
fi
