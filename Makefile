# Провижнинг прод-стенда SensitivityScore с одного хоста одной командой:
# подготовка ОС (Ansible) -> k8s (k0sctl) -> тестбед (bench-репозиторий) -> проверки.

ANSIBLE        ?= ansible-playbook
PYTHON         ?= python3
INVENTORY      ?= inventory/hosts.yml
KUBECONFIG_OUT ?= $(CURDIR)/kubeconfig
BENCH_REPO     ?= ../sensitivityscore-hpc-bench
# Имя ss-system-узла в k8s (см. inventory). Комментарий — отдельной строкой:
# в make всё до `#` попадает в значение вместе с пробелами перед ним.
SS_SYSTEM_NODE ?= sssystem

# Коллекции берём из requirements.yml, чтобы список не разъезжался с deps.
COLLECTIONS = $(shell awk '$$1=="-" && $$2=="name:" {print $$3}' requirements.yml)

# Инструментарий ставим в репозиторий, а не в систему: версия k0sctl
# фиксирована (воспроизводимость стенда), а python-пакет kubernetes ставить
# в системный интерпретатор нельзя — на macOS и свежих Debian/Ubuntu он
# externally-managed (PEP 668), pip туда откажет. Обе директории в .gitignore.
VENV           ?= $(CURDIR)/.venv
BIN            ?= $(CURDIR)/bin
K0SCTL         ?= $(BIN)/k0sctl
K0SCTL_VERSION ?= v0.32.1
K0SCTL_OS      ?= $(shell uname -s | tr 'A-Z' 'a-z')
K0SCTL_ARCH    ?= $(shell uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
K0SCTL_URL      = https://github.com/k0sproject/k0sctl/releases/download/$(K0SCTL_VERSION)/k0sctl-$(K0SCTL_OS)-$(K0SCTL_ARCH)

# Свой bin впереди PATH: cluster.yml зовёт k0sctl по имени, и брать надо
# зафиксированную версию, а не случайную из системы.
export PATH := $(BIN):$(PATH)

# preflight по умолчанию доставляет недостающее. PREFLIGHT_INSTALL=0 —
# только проверить и ничего не менять (CI, чужая машина).
PREFLIGHT_INSTALL ?= 1

.DEFAULT_GOAL := help

.PHONY: help
help: ## список целей
	@grep -hE '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# Интерпретатор для модулей kubernetes.core задаётся в
# inventory/host_vars/localhost.yml: эта .venv, если она есть, иначе прежний
# python (значит пакет поставлен глобально — тоже рабочий вариант).
$(K0SCTL):
	@mkdir -p $(BIN)
	@echo "качаю k0sctl $(K0SCTL_VERSION) ($(K0SCTL_OS)/$(K0SCTL_ARCH))"
	@curl -fsSL -o $(K0SCTL) $(K0SCTL_URL) || { \
		echo "не скачался: $(K0SCTL_URL)"; rm -f $(K0SCTL); exit 1; }
	@chmod +x $(K0SCTL)
	@$(K0SCTL) version >/dev/null || { echo "скачанный k0sctl не запускается"; rm -f $(K0SCTL); exit 1; }

# pip запускается всегда, а не по file-таргету: venv может существовать, а
# пакета в нём не быть (удалили, оборвалась установка) — тогда таргет по файлу
# счёл бы всё готовым. Повторный install при удовлетворённом требовании — no-op.
.PHONY: deps
deps: $(K0SCTL) ## доставить всё нужное: коллекции, python-kubernetes (.venv), k0sctl
	ansible-galaxy collection install -r requirements.yml
	@test -d $(VENV) || $(PYTHON) -m venv $(VENV)
	@$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet kubernetes

.PHONY: deps-clean
deps-clean: ## удалить локально поставленный инструментарий (.venv, bin)
	rm -rf $(VENV) $(BIN)

# Провижининг падает дорого: нехватка k0sctl или python-kubernetes всплывает
# на шагах cluster/storage, то есть уже ПОСЛЕ prep — когда 7 узлов
# перенастроены, а то и кластер поднят. Здесь весь инструментарий проверяется
# до первого изменения на узлах, и перечисляются сразу все пробелы, а не по
# одному за прогон.
# Делится на две части: что можно доставить самим (коллекции, python-пакет,
# k0sctl) и что доставить нельзя — сам ansible (им же и ставим остальное),
# инвентарь (данные оператора) и bench-репа (не пакет, и путь настраиваемый).
# Первое ставится, второе печатается с готовой командой.
.PHONY: preflight
preflight: ## проверить окружение и доставить недостающее (PREFLIGHT_INSTALL=0 — только проверка)
	@blocked=0; auto=0; \
	command -v $(ANSIBLE) >/dev/null 2>&1 || { echo "  нет $(ANSIBLE) — pip install ansible"; blocked=1; }; \
	test -f $(INVENTORY) || { echo "  нет инвентаря $(INVENTORY)"; blocked=1; }; \
	test -f $(BENCH_REPO)/Makefile || { echo "  нет bench-репы в $(BENCH_REPO) (нужна make testbed):"; \
		echo "      git clone git@github.com:AndreyZa/sensitivityscore-hpc-bench.git $(BENCH_REPO)"; blocked=1; }; \
	command -v k0sctl >/dev/null 2>&1 || { echo "  нет k0sctl (нужен make cluster)"; auto=1; }; \
	miss=""; have="$$(ansible-galaxy collection list 2>/dev/null)"; \
	for c in $(COLLECTIONS); do echo "$$have" | grep -q "^$$c " || miss="$$miss $$c"; done; \
	[ -z "$$miss" ] || { echo "  нет коллекций:$$miss"; auto=1; }; \
	: "Проверяем ровно тот интерпретатор, которым пойдут модули (см." ; \
	: "inventory/host_vars/localhost.yml): сначала .venv, иначе — модулем," ; \
	: "потому что python3 из PATH может быть не тем, что берёт ansible." ; \
	if [ -x $(VENV)/bin/python ]; then \
		$(VENV)/bin/python -c 'import kubernetes' 2>/dev/null \
			|| { echo "  в .venv нет python-пакета kubernetes"; auto=1; }; \
	elif [ -z "$$miss" ]; then \
		ansible localhost -m community.general.python_requirements_info \
			-a dependencies=kubernetes 2>/dev/null | grep -q 'not_found: \[\]' \
			|| { echo "  нет python-пакета kubernetes (нужен kubernetes.core)"; auto=1; }; \
	else auto=1; fi; \
	if [ $$auto -eq 1 ] && [ $$blocked -eq 0 ] && [ "$(PREFLIGHT_INSTALL)" = "1" ]; then \
		echo "-> доставляю недостающее"; \
		$(MAKE) --no-print-directory deps || { echo "preflight: доставить не удалось"; exit 1; }; \
		echo "-> перепроверяю"; \
		$(MAKE) --no-print-directory preflight PREFLIGHT_INSTALL=0; exit $$?; \
	fi; \
	if [ $$auto -eq 1 ]; then \
		blocked=1; \
		[ "$(PREFLIGHT_INSTALL)" = "1" ] || echo "  (доставляется: make deps)"; \
	fi; \
	[ $$blocked -eq 0 ] && echo "preflight OK" || { echo "preflight: окружение не готово (см. выше)"; exit 1; }

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

# Оба стека прибиты к ss-system и потому идут ПОСЛЕ testbed (он вешает метку
# роли) и ПОСЛЕ storage: PVC ClickHouse просит том без storageClassName и без
# класса по умолчанию молча повиснет в Pending.
MONITORING_OVERLAY_PROD ?= k8s/monitoring/overlays/prod
CH_KUSTOMIZE_PROD       ?= k8s/clickhouse/overlays/prod

.PHONY: monitoring
monitoring: ## Prometheus + Grafana на ss-system (prod-overlay bench-репы)
	KUBECONFIG=$(KUBECONFIG_OUT) $(MAKE) -C $(BENCH_REPO) monitoring-deploy \
		MONITORING_OVERLAY=$(MONITORING_OVERLAY_PROD)

.PHONY: clickhouse
clickhouse: ## in-cluster ClickHouse на ss-system (приёмник результатов прода)
	KUBECONFIG=$(KUBECONFIG_OUT) $(MAKE) -C $(BENCH_REPO) ch-incluster-deploy \
		CH_KUSTOMIZE=$(CH_KUSTOMIZE_PROD)

.PHONY: check
check: ## пост-проверки (paranoid, PSI, ноды Ready)
	$(ANSIBLE) -i $(INVENTORY) playbooks/check.yml

.PHONY: provision
provision: preflight prep cluster testbed storage clickhouse monitoring check ## полный цикл: ОС -> кластер -> тестбед -> хранилище -> ClickHouse+мониторинг -> проверки
	@echo "OK — стенд поднят. kubeconfig: $(KUBECONFIG_OUT)"
