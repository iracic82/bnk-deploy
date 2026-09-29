# Registry auth, namespaces and the pull secret. The secret must exist in BOTH namespaces.
cat "$FAR_PULL_JSON" | helm registry login --username _json_key_base64 --password-stdin "$CNE_REPO" >/dev/null
ok "logged in to ${CNE_REPO}"

for ns in "$NS_CORE" "$NS_BNK"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry far-pull-secret \
    --docker-server="$CNE_REPO" \
    --docker-username=_json_key_base64 \
    --docker-password="$(cat "$FAR_PULL_JSON")" \
    --namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "$ns namespace and far-pull-secret"
done
