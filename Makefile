# Провижнинг прод-стенда SensitivityScore «по кнопке» с одного хоста:
# OS-prep (Ansible) -> k8s (k0sctl) -> тестбед (bench-репа) -> проверки.

ANSIBLE        ?= ansible-playbook
INVENTORY      ?= inventory/hosts.yml
KUBECONFIG_OUT ?= $(CURDIR)/kubeconfig
BENCH_REPO     ?= ../sensitivityscore-hpc-bench
SS_SYSTEM_NODE ?= sssystem   # имя ss-system-узла в k8s (см. inventory)

.DEFAULT_GOAL := help

.PHONY: help
help: ## список целей
	@grep -hE '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## установить ansible-коллекции (requirements.yml)
	ansible-galaxy collection install -r requirements.yml

.PHONY: ping
ping: ## проверить SSH-доступность всех узлов
	ansible -i $(INVENTORY) all -m ping

.PHONY: lint
lint: ## yamllint + ansible-lint + syntax-check всех плейбуков
	yamllint .
	ansible-lint
	@for pb in playbooks/*.yml; do \
		ansible-playbook --syntax-check $$pb >/dev/null && echo "syntax ok  $$pb"; \
	done

.PHONY: dry-run
dry-run: ## prep в режиме --check --diff — показать, что изменилось бы, ничего не меняя
	$(ANSIBLE) -i $(INVENTORY) playbooks/prep.yml --check --diff

.PHONY: prep
prep: ## OS-подготовка всех узлов (Ubuntu/perf/PSI/swap/время/governor)
	$(ANSIBLE) -i $(INVENTORY) playbooks/prep.yml

.PHONY: cluster
cluster: ## поднять k0s HA-кластер и записать ./kubeconfig
	$(ANSIBLE) -i $(INVENTORY) playbooks/cluster.yml

.PHONY: testbed
testbed: ## роли узлов + Redis/scheduler/agent (через bench-репу)
	KUBECONFIG=$(KUBECONFIG_OUT) $(MAKE) -C $(BENCH_REPO) setup-cluster SS_NODES=$(SS_SYSTEM_NODE)

.PHONY: check
check: ## пост-проверки (paranoid, PSI, ноды Ready)
	$(ANSIBLE) -i $(INVENTORY) playbooks/check.yml

.PHONY: provision
provision: prep cluster testbed check ## КНОПКА: от 0 до задеплоенного стенда
	@echo "OK — стенд поднят. kubeconfig: $(KUBECONFIG_OUT)"
