# prod-provision

Провижнинг прод-стенда SensitivityScore **с одного хоста по кнопке**.
Разворачивает k8s-кластер стенда с нуля и передаёт его в
[`../sensitivityscore-hpc-bench`](../sensitivityscore-hpc-bench) для деплоя
тестбеда (Redis, планировщик, metrics-agent).

## Топология стенда

| Группа | Узлы | Роль k8s | Железо |
|--------|------|----------|--------|
| `controllers` | cp1, cp2, cp3 | control-plane (HA etcd) | 3 ВМ · 4 vCPU / 8 ГБ / 100 ГБ SSD |
| `ss_system` | sssystem | worker (role `ss-system` + taint) | 1 ВМ · 4 vCPU / 8 ГБ / 100 ГБ SSD |
| `bench` | bench1–3 | worker (role `bench`) | 3× Dell R760, 2× Xeon Platinum 8462Y+, 384 ГБ |

ВМ — на отдельном гипервизор-хосте, **не на R760** (иначе фоновая нагрузка
etcd/ClickHouse исказит метрики). Подробности — `../sensitivityscore-hpc-bench/docs/Ввод прод-стенда (Этап 0).md`.

## Стек

- **Ansible** — подготовка ОС всех узлов (Ubuntu 24.04: `perf_event_paranoid`,
  PSI, cgroup v2, swap off, время, CPU-governor на bench).
- **k0sctl** — bootstrap кластера k0s (тот же дистрибутив, что на STAGE).
  `k0sctl.yaml` **генерируется** из ansible-инвентаря (один источник истины).
- **Хендофф** — роли узлов + компоненты тестбеда через `make setup-cluster`
  bench-репы (логика не дублируется).

## Предпосылки (на хосте-операторе)

- `ansible` (+ коллекции: `make deps`), `k0sctl`, `kubectl`, `make`.
- SSH-ключ с доступом root/sudo на все 7 узлов (`ssh_key_path` в
  `inventory/group_vars/all.yml`).
- ОС на узлах — Ubuntu Server 24.04 LTS, уже установлена и доступна по SSH.

## Как пользоваться

1. Заполнить `inventory/hosts.yml` (адреса, ssh-пользователь) и при необходимости
   `inventory/group_vars/all.yml` (версия k0s, ключ, governor).
2. Проверить доступность: `make ping`.
3. Кнопка:

   ```bash
   make provision
   ```

   Это: `prep` (OS) → `cluster` (k0s, пишет `./kubeconfig`) → `testbed`
   (роли + Redis/scheduler/agent через bench-репу) → `check`.

Гранулярно — те же шаги по отдельности: `make prep`, `make cluster`,
`make testbed`, `make check`. `make help` — список целей.

После `make provision` кластер готов к прогонам: см. `../sensitivityscore-hpc-bench/README.md`
(калибровки Net/LLC, `make series`).

## Альтернативы стека

- Чистый Ansible без k0sctl (kubeadm/k0s-роль) — можно, но HA-джойн трёх
  контроллеров k0sctl делает надёжнее и в одну команду.
- Managed control-plane (как Timeweb k0s на STAGE) — тогда 3 CP-ВМ не нужны,
  provision сводится к OS-prep bench+ss-system и хендоффу.
