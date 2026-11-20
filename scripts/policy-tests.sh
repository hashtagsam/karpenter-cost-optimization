#!/usr/bin/env bash
# Policy-as-code unit tests, run in CI and locally (`make test-policies`).
#   1. Every manifest we ship must PASS all policies (no fail, no error).
#   2. Every known-bad fixture must FAIL at least one policy.
# Requires: kyverno CLI (>= 1.19), kustomize or kubectl, yq (mikefarah or python-yq).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICIES="$ROOT/platform/kyverno/policies"
TESTS="$ROOT/platform/kyverno/tests"
KYVERNO="${KYVERNO:-kyverno}"

# kustomize binary if present, otherwise kubectl's built-in kustomize
render() {
  if command -v "${KUSTOMIZE:-kustomize}" >/dev/null 2>&1; then
    "${KUSTOMIZE:-kustomize}" build "$1"
  else
    kubectl kustomize "$1"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
  # Print the PolicyReport (YAML) for the given resource files
  local args=()
  for f in "$@"; do args+=(--resource "$f"); done
  # kyverno exits non-zero when any policy fails; we assert on the report instead
  { "$KYVERNO" apply "$POLICIES" "${args[@]}" -f "$TESTS/values.yaml" --policy-report 2>/dev/null || true; } \
    | sed -n '/^apiVersion/,$p'
}

echo "==> Rendering shipped manifests"
render "$ROOT/k8s/demo-app" > "$WORK/demo-app.yaml"
render "$ROOT/k8s/loadtest" > "$WORK/loadtest.yaml"
cp "$ROOT/k8s/demo-app/inflate.yaml" "$TESTS/good-critical.yaml" "$WORK/"

echo "==> Shipped manifests must pass every policy"
report "$WORK/demo-app.yaml" "$WORK/loadtest.yaml" "$WORK/inflate.yaml" "$WORK/good-critical.yaml" > "$WORK/good.report"
bad_results="$(yq -r '.results[] | select(.result == "fail" or .result == "error") | .policy + " -> " + .resources[0].name + ": " + .message' "$WORK/good.report")"
if [[ -n "$bad_results" ]]; then
  echo "FAIL: shipped manifests violate policy:"
  echo "$bad_results"
  exit 1
fi
echo "    ok"

echo "==> Every bad fixture must be rejected"
report "$TESTS/bad-workloads.yaml" > "$WORK/bad.report"
expected="$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$TESTS/bad-workloads.yaml" | grep -v -- '---' | sort -u)"
rejected="$(yq -r '.results[] | select(.result == "fail") | .resources[0].name' "$WORK/bad.report" | sort -u)"
missing="$(comm -23 <(echo "$expected") <(echo "$rejected"))"
if [[ -n "$missing" ]]; then
  echo "FAIL: these bad fixtures were NOT rejected:"
  echo "$missing"
  exit 1
fi
echo "    ok ($(echo "$expected" | wc -l | tr -d ' ') bad fixtures rejected)"

echo "All policy tests passed."