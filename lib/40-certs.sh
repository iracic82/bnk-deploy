# CWC and OTEL certificates.
# The CWC certs come from a shell script in the cert-gen chart, which is the least declarative
# part of the whole install. The OTEL certs are plain cert-manager Certificates.
[[ "$DRY_RUN" == "1" ]] && { warn "dry run, skipping cert generation"; return 0; }

if kubectl get secret -n "$NS_CORE" cwc-license-certs >/dev/null 2>&1 \
   || kubectl get secret -n "$NS_CORE" -o name 2>/dev/null | grep -q cwc; then
  ok "CWC certs already present"
else
  work=$(mktemp -d)
  # pushd must not be allowed to fail silently, or the applies below run in the wrong directory
  pushd "$work" >/dev/null || die "cannot enter $work"
  helm pull "oci://${CNE_REPO}/utils/f5-cert-gen" --version "$CERT_GEN_VERSION" >/dev/null
  tar xzf f5-cert-gen-*.tgz
  sh cert-gen/gen_cert.sh -s=api-server -a="f5-spk-cwc.${NS_CORE}.svc.cluster.local" -n=1 >/dev/null
  kubectl apply -n "$NS_CORE" -f cwc-license-certs.yaml -f cwc-license-client-certs.yaml >/dev/null
  popd >/dev/null || true
  rm -rf "$work"
  ok "CWC certs generated with cert-gen ${CERT_GEN_VERSION}"
fi

for name in external-otelsvr external-f5ingotelsvr; do
kubectl apply -n "$NS_CORE" -f - <<YAML >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${name}
spec:
  commonName: otel.cluster.local
  secretName: ${name}-secret
  issuerRef: { name: ${CLUSTER_ISSUER}, kind: ClusterIssuer }
  duration: 8640h
  privateKey: { rotationPolicy: Always, encoding: PKCS1, algorithm: RSA, size: 4096 }
YAML
done
ok "OTEL certificates applied"
