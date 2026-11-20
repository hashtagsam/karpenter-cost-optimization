# Karpenter cost-optimisation lab
# `make help` lists targets. Typical flow:
#   make bootstrap        (once)  -> remote state + GitHub OIDC roles
#   make up                       -> infra + platform + demo app
#   make loadtest & make watch    -> see Karpenter scale out / consolidate
#   make report                   -> cost snapshot (docs/results.md)
#   make down                     -> safe teardown + orphan check

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TF_DIR        := terraform/envs/dev
BOOTSTRAP_DIR := terraform/bootstrap

# Pinned chart versions (bump deliberately, test in dev first)
KARPENTER_VERSION      ?= 1.15.2
KYVERNO_CHART_VERSION  ?= 3.9.2
KPS_CHART_VERSION      ?= 93.3.0
OPENCOST_CHART_VERSION ?= 2.5.34
METRICS_SERVER_VERSION ?= 3.14.0

# Node AMI. Pin in prod, e.g. AMI_ALIAS=bottlerocket@v1.x.y
AMI_ALIAS ?= bottlerocket@latest

# Read lazily from Terraform outputs
tf_out = $(shell terraform -chdir=$(TF_DIR) output -raw $(1) 2>/dev/null)
CLUSTER_NAME        = $(call tf_out,cluster_name)
REGION              = $(call tf_out,region)
KARPENTER_QUEUE     = $(call tf_out,karpenter_interruption_queue)
KARPENTER_NODE_ROLE = $(call tf_out,karpenter_node_role_name)
PROJECT             ?= karpenter-costopt
ENVIRONMENT         ?= dev
COST_CENTER         ?= platform-engineering

# Baseline being replaced: a static, peak-sized on-demand node group
BASELINE_TYPE  ?= m6i.xlarge
BASELINE_COUNT ?= 6

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

##@ Infrastructure (Terraform)
.PHONY: bootstrap init plan apply kubeconfig
bootstrap: ## One-off: state bucket + GitHub OIDC roles (local state)
	terraform -chdir=$(BOOTSTRAP_DIR) init
	terraform -chdir=$(BOOTSTRAP_DIR) apply

init: ## terraform init for the dev environment (needs backend.hcl)
	@test -f $(TF_DIR)/backend.hcl || { echo "Create $(TF_DIR)/backend.hcl from backend.hcl.example"; exit 1; }
	terraform -chdir=$(TF_DIR) init -backend-config=backend.hcl

plan: ## terraform plan (dev)
	terraform -chdir=$(TF_DIR) plan -out=tfplan

apply: ## terraform apply the saved plan (dev)
	terraform -chdir=$(TF_DIR) apply tfplan

kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER_NAME)


##@ Platform add-ons
.PHONY: platform karpenter nodepools metrics-server kyverno monitoring opencost
platform: karpenter nodepools metrics-server kyverno monitoring opencost ## Install every add-on in order

karpenter: ## Install Karpenter (CRDs chart first, so upgrades update CRDs too)
	helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
	  --version $(KARPENTER_VERSION) --namespace kube-system
	helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
	  --version $(KARPENTER_VERSION) --namespace kube-system \
	  -f platform/karpenter/values.yaml \
	  --set settings.clusterName=$(CLUSTER_NAME) \
	  --set settings.interruptionQueue=$(KARPENTER_QUEUE) \
	  --wait

nodepools: ## Apply EC2NodeClass + NodePools (rendered with envsubst)
	@for f in ec2nodeclass nodepool-general nodepool-critical; do \
	  CLUSTER_NAME=$(CLUSTER_NAME) KARPENTER_NODE_ROLE=$(KARPENTER_NODE_ROLE) AMI_ALIAS=$(AMI_ALIAS) \
	  PROJECT=$(PROJECT) ENVIRONMENT=$(ENVIRONMENT) COST_CENTER=$(COST_CENTER) \
	  envsubst '$${CLUSTER_NAME} $${KARPENTER_NODE_ROLE} $${AMI_ALIAS} $${PROJECT} $${ENVIRONMENT} $${COST_CENTER}' \
	    < platform/karpenter/$$f.yaml | kubectl apply -f - ; \
	done

metrics-server: ## metrics-server (HPA needs it), pinned to system nodes
	helm upgrade --install metrics-server metrics-server \
	  --repo https://kubernetes-sigs.github.io/metrics-server/ --version $(METRICS_SERVER_VERSION) \
	  --namespace kube-system \
	  --set nodeSelector.node-role=system \
	  --set 'tolerations[0].key=CriticalAddonsOnly' --set 'tolerations[0].operator=Exists' \
	  --wait

kyverno: ## Kyverno + cost/security guardrail policies
	helm upgrade --install kyverno kyverno \
	  --repo https://kyverno.github.io/kyverno/ --version $(KYVERNO_CHART_VERSION) \
	  --namespace kyverno --create-namespace -f platform/kyverno/values.yaml --wait
	kubectl apply -f platform/kyverno/policies/

monitoring: ## Prometheus + Grafana (+ Karpenter dashboards, alerts)
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || \
	  kubectl -n monitoring create secret generic grafana-admin \
	    --from-literal=admin-user=admin \
	    --from-literal=admin-password="$$(openssl rand -base64 24)"
	helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
	  --repo https://prometheus-community.github.io/helm-charts --version $(KPS_CHART_VERSION) \
	  --namespace monitoring -f platform/monitoring/kube-prometheus-stack.values.yaml --wait --timeout 10m
	kubectl apply -f platform/monitoring/karpenter-monitoring.yaml

opencost: ## OpenCost cost allocation (by namespace/label)
	helm upgrade --install opencost opencost \
	  --repo https://opencost.github.io/opencost-helm-chart --version $(OPENCOST_CHART_VERSION) \
	  --namespace opencost --create-namespace \
	  -f platform/monitoring/opencost.values.yaml \
	  --set opencost.exporter.defaultClusterId=$(CLUSTER_NAME) --wait



##@ Demo
.PHONY: up app inflate deflate loadtest watch report cost-watch grafana opencost-ui grafana-password
up: init plan apply kubeconfig platform app ## Everything: infra -> platform -> app

app: ## Deploy podinfo (HPA, PDB, NetworkPolicies) + the inflate deployment
	kubectl apply -k k8s/demo-app
	kubectl apply -f k8s/demo-app/inflate.yaml

inflate: ## Quick demo: 30 x 1 vCPU pods -> watch Karpenter launch nodes
	kubectl -n demo scale deployment/inflate --replicas=30

deflate: ## Scale inflate to 0 -> watch consolidation remove nodes
	kubectl -n demo scale deployment/inflate --replicas=0

loadtest: ## Run the k6 load test (≈15 min) against podinfo
	kubectl delete job k6-load -n loadtest --ignore-not-found
	kubectl apply -k k8s/loadtest
	@echo "Follow with: kubectl -n loadtest logs -f job/k6-load"

watch: ## Live view of nodes / NodeClaims / HPA
	scripts/watch-nodes.sh 5

report: ## Cost snapshot -> docs/results.md
	python3 scripts/cost_report.py --cluster $(CLUSTER_NAME) --region $(REGION) \
	  --baseline-instance-type $(BASELINE_TYPE) --baseline-count $(BASELINE_COUNT) \
	  --markdown docs/results.md

cost-watch: ## Append a cost sample every 60s to docs/cost-timeseries.csv (Ctrl-C to stop)
	while true; do \
	  python3 scripts/cost_report.py --cluster $(CLUSTER_NAME) --region $(REGION) \
	    --baseline-instance-type $(BASELINE_TYPE) --baseline-count $(BASELINE_COUNT) \
	    --csv docs/cost-timeseries.csv --json >/dev/null && date -u +%T; \
	  sleep 60; \
	done

grafana: ## Port-forward Grafana to http://localhost:3000
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

grafana-password: ## Print the generated Grafana admin password
	@kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

opencost-ui: ## Port-forward OpenCost UI to http://localhost:9090
	kubectl -n opencost port-forward svc/opencost 9090:9090


##@ Quality gates (same checks as CI)
.PHONY: test fmt lint-tf test-policies test-python validate-manifests
test: fmt lint-tf validate-manifests test-policies test-python ## Run every local check

fmt: ## terraform fmt check
	terraform fmt -recursive -check terraform

lint-tf: ## tflint + checkov
	tflint --init --config=$(CURDIR)/.tflint.hcl
	tflint --chdir=$(TF_DIR) --config=$(CURDIR)/.tflint.hcl
	tflint --chdir=$(BOOTSTRAP_DIR) --config=$(CURDIR)/.tflint.hcl
	checkov -d . --config-file .checkov.yaml

validate-manifests: ## kubeconform (strict, incl. Karpenter/Kyverno CRDs) on rendered manifests
	scripts/validate-manifests.sh

test-policies: ## Kyverno policy unit tests
	scripts/policy-tests.sh

test-python: ## ruff + bandit + pytest for the cost report
	ruff check scripts tests && ruff format --check scripts tests
	bandit -q -r scripts
	python3 -m pytest -q

##@ Teardown
.PHONY: down
down: ## Safe teardown: Karpenter nodes first, then terraform destroy, then orphan check
	scripts/teardown.sh