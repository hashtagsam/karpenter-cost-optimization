#!/usr/bin/env bash
# Regenerate the JSON schemas kubeconform uses to validate our custom
# resources (Karpenter, Kyverno, Prometheus Operator). Run after bumping
# any of those versions; commit the result.
set -euo pipefail

KARPENTER_VERSION="${KARPENTER_VERSION:-1.15.2}"
KYVERNO_VERSION="${KYVERNO_VERSION:-1.19.2}"
PROM_OPERATOR_VERSION="${PROM_OPERATOR_VERSION:-v0.95.2}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.6.7}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/tests/schemas"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -sSfL -o "$WORK/openapi2jsonschema.py" \
  "https://raw.githubusercontent.com/yannh/kubeconform/${KUBECONFORM_VERSION}/scripts/openapi2jsonschema.py"

crds=(
  "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
  "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
  "https://raw.githubusercontent.com/kyverno/kyverno/v${KYVERNO_VERSION}/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml"
  "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"
  "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml"
)

mkdir -p "$OUT"
cd "$OUT"
for url in "${crds[@]}"; do
  curl -sSfL -o "$WORK/crd.yaml" "$url"
  FILENAME_FORMAT='{kind}_{version}' python3 "$WORK/openapi2jsonschema.py" "$WORK/crd.yaml"
done
# Keep only the API versions we actually use
rm -f "$OUT/validatingpolicy_v1alpha1.json" "$OUT/validatingpolicy_v1beta1.json"
ls -1 "$OUT"