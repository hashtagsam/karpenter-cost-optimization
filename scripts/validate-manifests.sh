#!/usr/bin/env bash
# Strict schema validation of every Kubernetes manifest we ship, including
# custom resources (schemas vendored in tests/schemas).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {
  if command -v "${KUSTOMIZE:-kustomize}" >/dev/null 2>&1; then
    "${KUSTOMIZE:-kustomize}" build "$1"
  else
    kubectl kustomize "$1"
  fi
}

render "$ROOT/k8s/demo-app" > "$WORK/demo-app.yaml"
render "$ROOT/k8s/loadtest" > "$WORK/loadtest.yaml"

# Render Karpenter templates with dummy values (the real ones come from Terraform)
export CLUSTER_NAME=ci-cluster KARPENTER_NODE_ROLE=ci-node-role AMI_ALIAS=bottlerocket@latest \
       PROJECT=ci ENVIRONMENT=ci COST_CENTER=ci
for f in ec2nodeclass nodepool-general nodepool-critical; do
  # shellcheck disable=SC2016  # literal list: only substitute these variables
  envsubst '${CLUSTER_NAME} ${KARPENTER_NODE_ROLE} ${AMI_ALIAS} ${PROJECT} ${ENVIRONMENT} ${COST_CENTER}' \
    < "$ROOT/platform/karpenter/$f.yaml" > "$WORK/$f.yaml"
done

"$KUBECONFORM" -strict -summary \
  -schema-location default \
  -schema-location "$ROOT/tests/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
  "$WORK"/*.yaml \
  "$ROOT/k8s/demo-app/inflate.yaml" \
  "$ROOT"/platform/kyverno/policies/*.yaml \
  "$ROOT/platform/monitoring/karpenter-monitoring.yaml"

# Optionally keep the rendered manifests (CI feeds them to the Checkov scan)
if [[ -n "${RENDER_DIR:-}" ]]; then
  mkdir -p "$RENDER_DIR" && cp "$WORK"/*.yaml "$ROOT/k8s/demo-app/inflate.yaml" "$RENDER_DIR"/
fi