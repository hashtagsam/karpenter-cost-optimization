#!/usr/bin/env bash
# Live view of what Karpenter is doing: nodes with pool, Spot/on-demand,
# instance type, zone and architecture, plus the podinfo HPA.
# Usage: scripts/watch-nodes.sh [interval-seconds]
set -euo pipefail

INTERVAL="${1:-5}"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "interval must be an integer" >&2; exit 1; }

while true; do
  clear
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  echo
  kubectl get nodes \
    -L karpenter.sh/nodepool \
    -L karpenter.sh/capacity-type \
    -L node.kubernetes.io/instance-type \
    -L topology.kubernetes.io/zone \
    -L kubernetes.io/arch \
    --sort-by=.metadata.creationTimestamp
  echo
  kubectl get nodeclaims 2>/dev/null || true
  echo
  kubectl -n demo get hpa podinfo 2>/dev/null || true
  sleep "$INTERVAL"
done