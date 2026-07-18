# hpc-k0s-provision

Провижнинг прод-стенда SensitivityScore **с одного хоста одной командой**.
Разворачивает k8s-кластер стенда с нуля и передаёт его в
[`sensitivityscore-hpc-bench`](https://github.com/AndreyZa/sensitivityscore-hpc-bench)
для деплоя тестбеда (Redis, планировщик, metrics-agent).

## Топология стенда

| Группа | Узлы | Роль k8s | Железо |
|--------|------|----------|--------|
| `controllers` | cp1, cp2, cp3 | control-plane (HA etcd, без kubelet) | 3 ВМ · 4 vCPU / 8 ГБ / 100 ГБ SSD |
| `ss_system` | sssystem | worker (роль `ss-system` + taint) | 1 ВМ · 4 vCPU / 8 ГБ / 100 ГБ SSD |
| `bench` | bench1–3 | worker (роль `bench`) | 3× Dell R760, 2× Xeon Platinum 8462Y+, 384 ГБ |

ВМ — на отдельном гипервизор-хосте, **не на R760** (иначе фоновая нагрузка
etcd/ClickHouse исказит метрики). Диск CP-ВМ — SSD: etcd чувствителен к
латентности fsync (`make check` включает пробу). Подробности — bench-репа,
`docs/Ввод прод-стенда (Этап 0).md`.

## Стек

- **Ansible** — подготовка ОС всех узлов (см. «Что настраивает prep» ниже).
- **k0sctl** — bootstrap кластера k0s (тот же дистрибутив, что на STAGE);
  `k0sctl.yaml` **генерируется** из ansible-инвентаря (один источник истины),
  телеметрия k0s выключена.
- **Хендофф** — роли узлов + компоненты тестбеда через `make setup-cluster`
  bench-репы (логика не дублируется).

## Что настраивает prep (все узлы, идемпотентно, переживает ребут)

- **Идентичность узла**: hostname = имя в инвентаре (`manage_hostname`; имя
  узла k8s берётся из hostname — на него завязан хендофф `SS_NODES=sssystem`),
  запись в `/etc/hosts`; assert уникальности `/etc/machine-id` (ловит ВМ,
  клонированные без sys-prep).
- **Требования k8s/kubelet**: swap off (сейчас + fstab), модули `overlay`,
  `br_netfilter` (modules-load.d), sysctl `ip_forward`, `bridge-nf-call-*`,
  inotify-лимиты (sysctl.d), assert cgroup v2.
- **Метрики стенда**: `perf_event_paranoid` (sysctl.d, значение из
  `group_vars`), assert PSI (`io.pressure`), linux-tools под текущее ядро.
- **Стабильность измерений**: chrony (время для makespan-таймстемпов),
  автообновления apt выключены (`disable_unattended_upgrades` — апгрейд
  посреди серии портит данные), на bench-узлах CPU governor = `performance`
  (сейчас + systemd-юнит `cpupower-governor.service` на ребут, `ondemand.service`
  отключён).

## Предпосылки (на хосте-операторе)

- `ansible` (+ коллекции: `make deps`), `k0sctl`, `kubectl`, `make`;
  для `make lint` — `ansible-lint`, `yamllint`.
- SSH-ключ на все 7 узлов (`ssh_key_path` в `inventory/group_vars/all.yml`),
  пользователь с **passwordless sudo** (нужен и Ansible, и k0sctl).
- ОС на узлах — Ubuntu Server 24.04 LTS, установлена и доступна по SSH.

## Как пользоваться

1. Заполнить `inventory/hosts.yml` (адреса, ssh-пользователь), при
   необходимости — `inventory/group_vars/all.yml` (версия k0s, ключ, переменные
   ниже).
2. Проверки перед прогоном:

   ```bash
   make lint      # yamllint + ansible-lint + syntax-check
   make ping      # SSH-доступность всех узлов
   make dry-run   # prep --check --diff: что изменилось бы, без изменений
   ```

3. Полный цикл:

   ```bash
   make provision
   ```

   Это: `prep` (ОС) → `cluster` (k0s, пишет `./kubeconfig`) → `testbed`
   (роли + Redis/scheduler/agent через bench-репу) → `storage` (StorageClass
   по умолчанию) → `check` (paranoid, PSI, swap, chrony, governor,
   fsync-проба etcd-диска, узлы Ready, наличие default StorageClass).

Гранулярно — те же шаги по отдельности: `make prep`, `make cluster`,
`make testbed`, `make storage`, `make check`. `make help` — список целей.

### Хранилище

`make storage` ставит `local-path-provisioner` и делает его StorageClass
**классом по умолчанию**. Это не украшение: манифесты стенда просят тома без
`storageClassName` (ClickHouse — `volumeClaimTemplates`), а такой PVC
связывается только при наличии дефолтного класса. Без него StatefulSet молча
висит в `Pending`, и отказ выглядит как «под не стартует», а не «нет
хранилища» — поэтому `make check` проверяет наличие класса явно.

Почему `local-path`, а не бандл OpenEBS: **чистота измерений**. local-path —
это один Deployment и ни одного DaemonSet, он прибивается к `ss-system`, и на
измерительных узлах не появляется ничего. OpenEBS 4.x тянет Mayastor с
DaemonSet'ами на все узлы, то есть постоянный посторонний процесс на `bench`
(см. bench-репа, «Ввод §2»). Встроенный `spec.extensions.storage.type:
openebs_local_storage` вдобавок объявлен устаревшим.

`reclaimPolicy: Retain` — намеренно, вместо апстримного `Delete`: удаление
PVC (или неймспейса) не должно уносить результаты серий. Цена — освободившиеся
тома остаются на диске и чистятся руками (`kubectl get pv`, каталог
`{{ local_path_dir }}` на узле).

Тома отдаёт узел, где встал **потребитель** (`WaitForFirstConsumer`), а
каталог создаёт короткоживущий helper-под на том же узле. Пока PVC просят
только системные компоненты (они прибиты к `ss-system`), на `bench` не
запускается ничего; если PVC попросит под серии — helper на секунды появится
на измерительном узле, для чистого прогона так не делать.

После `make provision` кластер готов к прогонам: см. README bench-репы
(калибровки Net/LLC, `make series`).

## Переменные (`inventory/group_vars/all.yml`)

| Переменная | Дефолт | Что делает |
|---|---|---|
| `k0s_version` | `v1.35.6+k0s.0` | версия k0s (та же, что на STAGE; ≥1.35 для config D) |
| `ssh_key_path` | `~/.ssh/id_ed25519` | ключ для ansible и k0sctl |
| `perf_event_paranoid` | `1` | значение sysctl (см. bench-репа, «Ввод §5») |
| `bench_cpu_governor` | `performance` | governor bench-узлов (persist через systemd) |
| `manage_hostname` | `true` | hostname = имя в инвентаре |
| `disable_unattended_upgrades` | `true` | выключить фоновые apt-обновления |
| `local_path_version` | `v0.0.36` | версия local-path-provisioner |
| `local_path_dir` | `/var/lib/sensitivityscore/local-path` | каталог томов на узле |

## CI

GitHub Actions (`.github/workflows/lint.yml`): yamllint + ansible-lint
(production-профиль) + syntax-check на каждый push/PR.

## Альтернативы стека

- Чистый Ansible без k0sctl (kubeadm/k0s-роль) — можно, но HA-джойн трёх
  контроллеров k0sctl делает надёжнее и в одну команду.
- Managed control-plane (как Timeweb k0s на STAGE) — тогда 3 CP-ВМ не нужны,
  provision сводится к OS-prep bench+ss-system и хендоффу.
