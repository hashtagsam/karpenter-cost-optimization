#!/usr/bin/env bash
# Safe teardown.
#
# Why this script exists: EC2 instances launched by Karpenter are NOT in
# Terraform state. If you run `terraform destroy` first, Terraform tries to
# delete the VPC/subnets/security groups while Karpenter nodes still use
# them -> the destroy hangs or fails and you keep paying for orphaned
# instances. So: let Karpenter remove its own nodes first, then destroy,
# then verify nothing was left behind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform/envs/dev"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in terraform kubectl helm aws; do
  command -v "$bin" >/dev/null || die "'$bin' is required"
done

CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null || true)"
REGION="$(terraform -chdir="$TF_DIR" output -raw region 2>/dev/null || true)"
[[ -n "$CLUSTER_NAME" && -n "$REGION" ]] || die "Could not read Terraform outputs - is the stack deployed?"

log "Tearing down cluster '$CLUSTER_NAME' in $REGION"
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Type the cluster name to confirm: " answer
  [[ "$answer" == "$CLUSTER_NAME" ]] || die "Confirmation did not match - aborting."
fi

if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1 \
   && kubectl get --raw=/readyz >/dev/null 2>&1; then

  log "1/4 Removing workloads"
  kubectl delete -k "$ROOT/k8s/loadtest" --ignore-not-found --wait=false || true
  kubectl delete -f "$ROOT/k8s/demo-app/inflate.yaml" --ignore-not-found || true
  kubectl delete -k "$ROOT/k8s/demo-app" --ignore-not-found || true

  log "2/4 Deleting NodePools so Karpenter drains and terminates its own nodes"
  kubectl delete nodepools --all --ignore-not-found || true
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while true; do
    remaining="$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$remaining" == "0" ]] && break
    (( SECONDS > deadline )) && { warn "$remaining NodeClaims still present after ${TIMEOUT_SECONDS}s"; break; }
    echo "    waiting for $remaining NodeClaim(s) to terminate..."
    sleep 15
  done
  kubectl delete ec2nodeclasses --all --ignore-not-found || true

  log "3/4 Uninstalling add-ons"
  for rel in "opencost opencost" "kube-prometheus-stack monitoring" "kyverno kyverno" \
             "metrics-server kube-system" "karpenter kube-system" "karpenter-crd kube-system"; do
    read -r name ns <<<"$rel"
    helm uninstall "$name" -n "$ns" --wait --timeout 5m 2>/dev/null || true
  done
else
  warn "Cluster API not reachable - skipping in-cluster cleanup, will check for orphans afterwards."
fi

log "4/4 terraform destroy"
if [[ "${AUTO_APPROVE:-0}" == "1" ]]; then
  terraform -chdir="$TF_DIR" destroy -auto-approve
else
  terraform -chdir="$TF_DIR" destroy
fi

log "Checking for orphaned Karpenter resources (these would keep billing)"
orphans="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
templates="$(aws ec2 describe-launch-templates --region "$REGION" \
  --filters "Name=tag:karpenter.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
  --query 'LaunchTemplates[].LaunchTemplateName' --output text)"

if [[ -n "$orphans" || -n "$templates" ]]; then
  warn "Orphaned instances: ${orphans:-none}"
  warn "Orphaned launch templates: ${templates:-none}"
  die "Clean these up manually (aws ec2 terminate-instances / delete-launch-template)."
fi

log "Clean: no orphaned instances or launch templates. Nothing left billing."