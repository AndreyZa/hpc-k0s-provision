# Провижнинг прод-стенда SensitivityScore с одного хоста одной командой:
# подготовка ОС (Ansible) -> k8s (k0sctl) -> тестбед (bench-репозиторий) -> проверки.

ANSIBLE        ?= ansible-playbook
INVENTORY      ?= inventory/hosts.yml
KUBECONFIG_OUT ?= $(CURDIR)/kubeconfig
BENCH_REPO     ?= ../sensitivityscore-hpc-bench
# Имя ss-system-узла в k8s (см. inventory). Комментарий — отдельной строкой:
# в make всё до `#` попадает в значение вместе с пробелами перед ним.
SS_SYSTEM_NODE ?= sssystem

# Коллекции берём из requirements.yml, чтобы список не разъезжался с deps.
COLLECTIONS = $(shell awk '$$1=="-" && $$2=="name:" {print $$3}' requirements.yml)

.DEFAULT_GOAL := help

.PHONY: help
help: ## список целей
	@grep -hE '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## установить ansible-коллекции (requirements.yml)
	ansible-galaxy collection install -r requirements.yml

# Провижининг падает дорого: нехватка k0sctl или python-kubernetes всплывает
# на шагах cluster/storage, то есть уже ПОСЛЕ prep — когда 7 узлов
# перенастроены, а то и кластер поднят. Здесь весь инструментарий проверяется
# до первого изменения на узлах, и перечисляются сразу все пробелы, а не по
# одному за прогон.
.PHONY: preflight
preflight: ## проверить окружение оператора (бинарники, коллекции, python-kubernetes, bench-репа)
	@fail=0; \
	command -v $(ANSIBLE) >/dev/null 2>&1 || { echo "  нет $(ANSIBLE) — pip install ansible"; fail=1; }; \
	command -v k0sctl   >/dev/null 2>&1 || { echo "  нет k0sctl (нужен make cluster) — github.com/k0sproject/k0sctl/releases"; fail=1; }; \
	test -f $(INVENTORY) || { echo "  нет инвентаря $(INVENTORY)"; fail=1; }; \
	test -f $(BENCH_REPO)/Makefile || { echo "  нет bench-репы в $(BENCH_REPO) (нужна make testbed) — склонировать рядом или задать BENCH_REPO="; fail=1; }; \
	missing=""; \
	have="$$(ansible-galaxy collection list 2>/dev/null)"; \
	for c in $(COLLECTIONS); do \
		echo "$$have" | grep -q "^$$c " || missing="$$missing $$c"; \
	done; \
	if [ -n "$$missing" ]; then echo "  нет коллекций:$$missing — make deps"; fail=1; \
	else \
		: "python-kubernetes проверяем модулем: важен интерпретатор, которым" ; \
		: "ansible запускает модули, а не python3 из PATH — в venv/pyenv они разные" ; \
		ansible localhost -m community.general.python_requirements_info \
			-a dependencies=kubernetes 2>/dev/null | grep -q 'not_found: \[\]' \
			|| { echo "  нет python-пакета kubernetes (нужен kubernetes.core: make storage, make check) — pip install kubernetes"; fail=1; }; \
	fi; \
	[ $$fail -eq 0 ] && echo "preflight OK" || { echo "preflight: окружение не готово (см. выше)"; exit 1; }

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

.PHONY: storage
storage: ## динамическое хранилище (local-path StorageClass по умолчанию)
	$(ANSIBLE) -i $(INVENTORY) playbooks/storage.yml

.PHONY: check
check: ## пост-проверки (paranoid, PSI, ноды Ready)
	$(ANSIBLE) -i $(INVENTORY) playbooks/check.yml

.PHONY: provision
provision: preflight prep cluster testbed storage check ## полный цикл: ОС -> кластер -> тестбед -> хранилище -> проверки
	@echo "OK — стенд поднят. kubeconfig: $(KUBECONFIG_OUT)"
