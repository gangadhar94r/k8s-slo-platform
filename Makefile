.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: check-rules
check-rules: ## Check Prometheus rule syntax
	promtool check rules rules/*.rules.yml

.PHONY: test-rules
test-rules: ## Unit test the alerting rules
	@for test in rules/tests/*_test.yml; do echo "== $$test"; promtool test rules "$$test" || exit 1; done

.PHONY: validate
validate: ## Validate manifests against the Kubernetes schema
	kubeconform -strict -summary -schema-location default manifests/

.PHONY: test-policy
test-policy: ## Unit test the guardrail policies
	conftest verify --policy policies

.PHONY: policy
policy: ## Apply guardrails to the manifests
	conftest test --policy policies manifests/

.PHONY: lint-shell
lint-shell: ## Lint the shell scripts
	shellcheck scripts/*.sh

.PHONY: check
check: check-rules test-rules validate test-policy policy lint-shell ## Everything CI runs

.PHONY: rules-configmap
rules-configmap: ## Build the slo-rules ConfigMap from rules/
	kubectl create configmap slo-rules \
		--namespace observability \
		--from-file=rules/ \
		--dry-run=client -o yaml

.PHONY: deploy
deploy: ## Apply everything to the current kube context
	kubectl apply -f manifests/namespace.yaml
	$(MAKE) rules-configmap | kubectl apply -f -
	kubectl apply -R -f manifests/
