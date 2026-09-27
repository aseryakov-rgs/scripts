#!/usr/bin/env bash
#
# diagnose-pgdg-pg18.sh — диагностика для AlmaLinux/RHEL 9 + PostgreSQL 18:
#                         почему `dnf install pg_repack_18` пишет
#                         «Нет соответствия аргументу / No match for argument».
#
# Запуск / usage:
#   ./diagnose-pgdg-pg18.sh            # только показать информацию (ничего не меняет)
#   sudo ./diagnose-pgdg-pg18.sh --fix # показать и попробовать починить (подключить репозиторий PGDG)
#
set -uo pipefail

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

hr()  { printf '%s\n' "------------------------------------------------------------------"; }
h()   { hr; printf '%s\n' "$*"; hr; }
log() { printf '[ .. ] %s\n' "$*"; }
ok()  { printf '[ OK ] %s\n' "$*"; }
wr()  { printf '[WARN] %s\n' "$*"; }
bad() { printf '[FAIL] %s\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; eval "$@" 2>&1 | sed 's/^/  /'; }

if ! command -v rpm >/dev/null 2>&1; then
  bad "это не RPM-система (AlmaLinux/RHEL/Rocky/Fedora). Запускайте скрипт на сервере с PostgreSQL 18."
  exit 1
fi

h "1. Система"
run "cat /etc/os-release | head -3"
run "uname -m"
run "command -v dnf || command -v yum"

h "2. Какой PostgreSQL установлен и откуда"
run "rpm -q postgresql18-server postgresql18 postgresql18-devel 2>&1"
run "rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE} (%{PACKAGER})\n' postgresql18-server 2>&1"
run "ls -l /usr/pgsql-18/bin/pg_config 2>&1"
run "/usr/pgsql-18/bin/pg_config --version 2>&1"
run "systemctl is-active postgresql-18 2>&1"

h "3. Подключён ли репозиторий PGDG"
run "rpm -q pgdg-redhat-repo 2>&1"
run "ls -1 /etc/yum.repos.d/ 2>&1"
PGDG_REPO_FILE="$(grep -Rls --include='*.repo' -e '^\[pgdg18\]' /etc/yum.repos.d/ 2>/dev/null | head -1)"
if [ -n "${PGDG_REPO_FILE:-}" ]; then
  ok "файл с секцией [pgdg18]: $PGDG_REPO_FILE"
  run "grep -A6 '^\[pgdg18\]' '$PGDG_REPO_FILE'"
else
  bad "нет ни одного файла .repo с секцией [pgdg18] — поэтому pg_repack_18 и postgresql18-* «не находятся»"
fi
run "dnf repolist 2>&1 | grep -i -E 'pgdg|postgres' || echo 'репозиториев pgdg в списке нет'"
run "dnf repolist --all 2>&1 | grep -i pgdg || echo 'PGDG-репозиториев нет вообще'"

h "4. Что видно dnf: есть ли pg_repack и postgresql18"
run "dnf list --available '*pg_repack*' 2>&1 | tail -5"
run "dnf list --available 'postgresql18*' 2>&1 | tail -5"

h "5. Итог: что делать"
NEED_REPO_FIX=0
if [ -z "${PGDG_REPO_FILE:-}" ]; then
  NEED_REPO_FIX=1
  cat <<'EOF'
  Причина: репозиторий PostgreSQL (PGDG) не подключён или устарел, поэтому
  пакета pg_repack_18 в списке нет.

  Выполните под root (или с sudo):

    # a) подключить/обновить репозиторий PGDG для EL-9
    sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
    sudo dnf -qy module disable postgresql        # отключает модуль postgresql из AppStream
    sudo dnf clean all

    # b) убедиться, что появились pgdg18 / pg_repack_18
    sudo dnf repolist | grep -i pgdg
    sudo dnf list --available '*pg_repack*'

    # c) поставить
    sudo dnf install -y pg_repack_18

    # d) включить расширение в нужных базах
    sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
EOF
fi
if [ -n "${PGDG_REPO_FILE:-}" ]; then
  if dnf repolist 2>/dev/null | grep -q '^pgdg18'; then
    ok "репозиторий pgdg18 включён — пробуем установить пакет командой: sudo dnf install -y pg_repack_18"
  else
    wr "секция [pgdg18] есть в файле, но репозиторий не активен (enabled=0?). Включите так:"
    cat <<'EOF'
    sudo dnf config-manager --set-enabled pgdg18
    sudo dnf install -y pg_repack_18
    # либо разово, без изменения настроек:
    # sudo dnf --enablerepo=pgdg18 install -y pg_repack_18
EOF
  fi
fi

if [ "$FIX" = 1 ]; then
  h "Режим --fix: подключаю репозиторий PGDG и ставлю pg_repack_18"
  SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || bad "не удалось подключить репозиторий PGDG (нет интернета?)"
  $SUDO dnf -qy module disable postgresql || true
  $SUDO dnf clean all >/dev/null 2>&1 || true
  if $SUDO dnf install -y pg_repack_18; then
    ok "пакет pg_repack_18 установлен"
    ls -l /usr/pgsql-18/bin/pg_repack /usr/pgsql-18/lib/pg_repack.so /usr/pgsql-18/share/extension/pg_repack.control 2>&1 | sed 's/^/  /'
    cat <<'EOF'

  Осталось включить расширение в каждой нужной базе (под суперпользователем):
    sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
    sudo -u postgres psql -d mydb -c "SELECT extname, extversion FROM pg_extension WHERE extname='pg_repack';"
EOF
  else
    bad "пакет установить не удалось. Тогда вариант 2 (make) или вариант 3 (rpmbuild) — см. pg_repack/README.md"
  fi
fi
hr
