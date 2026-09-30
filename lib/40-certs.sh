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
  # Not redirected to /dev/null any more. This script is the least declarative part of the install and
  # when it goes wrong the errors are the only evidence, so they belong in the log.
  sh cert-gen/gen_cert.sh -s=api-server -a="f5-spk-cwc.${NS_CORE}.svc.cluster.local" -n=1 \
    || warn "gen_cert.sh exited non-zero, checking what it produced"

  # gen_cert.sh writes its yaml even when the generation inside it failed, so the files existing
  # proves nothing. What matters is whether they carry a certificate. Without this the install
  # reported success and created CWC licence secrets containing nothing, and the failure surfaced
  # later as a licence that would not validate.
  # These are Secret manifests, so the certificates inside are base64 and grepping for
  # BEGIN CERTIFICATE finds nothing even in a perfectly good file. LS0tLS1CRUdJTi is the base64 of a
  # PEM header, present in a real file and absent from a failed one.
  #
  # The failure this guards against was seen on a bare Ubuntu VM: gen_cert.sh hit "make: not found",
  # every cat of a cert file then failed, and the yaml was still written with empty values. kubectl
  # accepts that without complaint, which is how the install used to report success and leave CWC
  # holding no certificates, surfacing much later as a licence that would not validate. Checked
  # against a real file and against that empty shape.
  for f in cwc-license-certs.yaml cwc-license-client-certs.yaml; do
    [[ -s "$f" ]] || die "cert-gen produced no $f. If 'make: not found' appeared above, install make and run again."
    grep -q 'LS0tLS1CRUdJTi' "$f" \
      || die "$f carries no certificate, so cert-gen failed while still writing the file. Look above for 'make: not found' or an openssl error."
  done
  kubectl apply -n "$NS_CORE" -f cwc-license-certs.yaml -f cwc-license-client-certs.yaml >/dev/null
  popd >/dev/null || true
  rm -rf "$work"

  # And confirm the cluster received real material, not just that apply exited zero.
  for sec in cwc-license-certs cwc-license-client-certs; do
    n=$(kubectl get secret "$sec" -n "$NS_CORE" -o jsonpath='{.data}' 2>/dev/null | grep -o '"' | wc -l)
    [[ "${n:-0}" -ge 6 ]] || die "secret $sec did not land with its three keys, so CWC has no usable certificates."
  done
  ok "CWC certs generated with cert-gen ${CERT_GEN_VERSION}, certificates verified present"
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
