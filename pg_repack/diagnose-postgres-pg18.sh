#!/usr/bin/env bash
#
# diagnose-postgres-pg18.sh — диагностика перед установкой pg_repack на
#                             AlmaLinux/RHEL 9 + PostgreSQL 18.
#
# Отвечает на вопросы:
#   1) чей у вас PostgreSQL: PGDG (postgresql18-*) или Postgres Pro (в т.ч. «для 1С», /opt/pgpro/...)
#   2) где лежит pg_config (без него собирать нельзя)
#   3) есть ли готовый пакет pg_repack в подключённых репозиториях
#      (PGDG: pg_repack_18; Postgres Pro: pg-repack-1c-18 / pg-repack-std-18 / pg-repack-ent-18)
#   4) какие команды выполнить дальше (make или dnf)
#
# Запуск / usage:
#   ./diagnose-postgres-pg18.sh            # только показать информацию
#   sudo ./diagnose-postgres-pg18.sh --fix # показать и, если возможно, установить готовый пакет
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

SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
PKG=""; for p in dnf yum; do command -v "$p" >/dev/null 2>&1 && { PKG="$p"; break; }; done

h "1. Система"
run "sed -n '1,3p' /etc/os-release"
run "uname -m"
run "command -v dnf || command -v yum || echo 'нет dnf/yum'"

h "2. Какой PostgreSQL установлен"
run "rpm -qa | grep -i -E 'postgres|pgpro|pg_repack|pg-repack' | sort"
run "ls -d /usr/pgsql-* /opt/pgpro/* /usr/local/pgsql 2>/dev/null"
run "systemctl list-units --type=service --no-legend 2>/dev/null | grep -i -E 'postgres|pgpro' | head -5"

h "3. Где pg_config (главное!)"
PG_CONFIG_BIN=""
if command -v pg_config >/dev/null 2>&1; then
  PG_CONFIG_BIN="$(command -v pg_config)"; ok "pg_config в PATH: $PG_CONFIG_BIN"
else
  wr "pg_config не в PATH — ищу по типовым путям"
  for c in /usr/pgsql-*/bin/pg_config /opt/pgpro/*/bin/pg_config /usr/lib/postgresql/*/bin/pg_config /usr/local/pgsql/bin/pg_config; do
    [ -x "$c" ] || continue
    PG_CONFIG_BIN="$c"; ok "найден: $c"
    break
  done
fi
if [ -n "$PG_CONFIG_BIN" ]; then
  run "'$PG_CONFIG_BIN' --version"
  run "'$PG_CONFIG_BIN' --bindir"
  run "'$PG_CONFIG_BIN' --pkglibdir"
  run "'$PG_CONFIG_BIN' --sharedir"
  run "'$PG_CONFIG_BIN' --libs"
  PGXS="$("$PG_CONFIG_BIN" --pgxs)"
  MF="$(dirname "$(dirname "$PGXS")")/Makefile.global"
  [ -r "$MF" ] && run "grep -E '^(with_llvm|CLANG|LLVM_BINPATH)' '$MF'"
else
  bad "pg_config не найден вовсе — значит не установлен dev-пакет (в нём pg_config, PGXS и заголовки)."
  run "$PKG provides '*/pg_config' 2>&1 | head -10"
fi

h "4. Репозитории и готовые пакеты pg_repack"
run "ls -1 /etc/yum.repos.d/"
run "grep -Hs -E '^\[|^baseurl|^enabled' /etc/yum.repos.d/*.repo 2>/dev/null | head -40"
# ВАЖНО: PGDG называет пакет pg_repack_18, а Postgres Pro — pg-repack-<редакция>-18,
# поэтому ищем двумя шаблонами: *pg_repack* и *repack*
run "$PKG list --available '*repack*' 2>&1 | tail -8"
run "$PKG list --installed '*repack*' 2>&1 | tail -5"
run "$PKG repolist 2>&1 | head -10"

h "5. Итог и что делать"

# определить «семейство» PostgreSQL
FAMILY="unknown"
case "${PG_CONFIG_BIN:-}" in
  /opt/pgpro/*) FAMILY="postgrespro" ;;
  /usr/pgsql-*) FAMILY="pgdg" ;;
  *) [ -n "${PG_CONFIG_BIN:-}" ] && FAMILY="other" ;;
esac
if [ -z "${PG_CONFIG_BIN:-}" ]; then
  if rpm -qa 2>/dev/null | grep -qi 'postgrespro-1c'; then FAMILY="postgrespro-installed-no-devel"
  elif rpm -qa 2>/dev/null | grep -qi '^postgresql1[0-9]'; then FAMILY="pgdg-no-devel"
  fi
fi

case "$FAMILY" in
  pgdg)
    cat <<EOF
  Похоже, у вас PostgreSQL из репозитория PGDG ($PG_CONFIG_BIN).

  Вариант «готовый пакет» (проще всего):
    sudo dnf install -y pg_repack_18
  Вариант «из исходников»:
    cd /tmp && curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
    tar -xzf ver_1.5.3.tar.gz && cd pg_repack-ver_1.5.3
    make        PG_CONFIG=$PG_CONFIG_BIN with_llvm=no
    sudo make install PG_CONFIG=$PG_CONFIG_BIN with_llvm=no
  Затем: sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
EOF
    ;;
  postgrespro|postgrespro-installed-no-devel)
    cat <<EOF
  У вас PostgreSQL от Postgres Professional (в т.ч. сборка «для 1С»): пакеты вида
  postgrespro-1c-18*, установка в /opt/pgpro/1c-18.

  !!! Важно: пакета pg_repack_18 (PGDG) в репозитории Postgres Pro НЕТ, поэтому
  !!! «dnf install pg_repack_18» здесь работать не будет — это ожидаемо.
  !!! И пакет pg_repack 1.4.6 из AppStream тоже не подходит: он для ванильного
  !!! PostgreSQL и не совпадёт с вашим сервером.

  1) Сначала проверьте, нет ли готового пакета от Postgres Pro (он называется
     pg-repack-1c-18 / pg-repack-std-18 / pg-repack-ent-18 — с дефисом, а не подчёркиванием):
       $PKG list --available '*repack*'
       $PKG install -y pg-repack-1c-18        # если нашелся

  2) Если готового пакета нет — собираем из исходников против ВАШЕГО pg_config:

     # a) dev-пакет (в нём pg_config, PGXS и заголовки сервера)
     $PKG list --available '*1c-18*' | head -20
     sudo $PKG install -y postgrespro-1c-18-devel
     # если имени нет — подскажет:  $PKG provides '*/pg_config'

     # b) инструменты и библиотеки
     sudo $PKG install -y gcc make zlib-devel readline-devel lz4-devel libzstd-devel openssl-devel

     # c) сборка (with_llvm=no — чтобы не требовались clang и llvm-lto)
     cd /tmp
     curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
     tar -xzf ver_1.5.3.tar.gz && cd pg_repack-ver_1.5.3
     make        PG_CONFIG=/opt/pgpro/1c-18/bin/pg_config with_llvm=no
     sudo make install PG_CONFIG=/opt/pgpro/1c-18/bin/pg_config with_llvm=no

     # d) включить расширение в базах (суперпользователем)
     sudo -u postgres /opt/pgpro/1c-18/bin/psql -d mydb -c "CREATE EXTENSION pg_repack;"

  3) Если dev-пакет достать нельзя — запасной путь: собрать pg_repack на этой же
     версии PostgreSQL из PGDG и перенести только серверный модуль:
       - на любой машине с postgresql18-devel: make ... && собрать lib/pg_repack.so
       - скопировать pg_repack.so в \$('$PG_CONFIG_BIN' --pkglibdir 2>/dev/null || echo /opt/pgpro/1c-18/lib),
         pg_repack.control и pg_repack--1.5.3.sql в <sharedir>/extension
     Этот путь совместим, но менее надёжен — проверяйте на тестовой базе.
EOF
    ;;
  *)
    cat <<EOF
  PostgreSQL 18 найден, но его происхождение определить не удалось.
  Пришлите вывод команд из разделов 2 и 3 — и станет ясно, откуда брать dev-пакет.

  Универсальный путь (если pg_config есть): собрать из исходников
     make PG_CONFIG=<ваш pg_config> with_llvm=no
     sudo make install PG_CONFIG=<ваш pg_config> with_llvm=no
EOF
    ;;
esac

if [ "$FIX" = 1 ]; then
  h "Режим --fix"
  if [ "${FAMILY}" = "pgdg" ]; then
    $SUDO $PKG install -y pg_repack_18 || bad "не удалось: возможно, репозиторий PGDG не подключён (см. README, раздел про pg_repack_18)"
  else
    log "пробую найти готовый пакет pg-repack-* в подключённых репозиториях"
    CAND="$($PKG -q list --available '*repack*' 2>/dev/null | awk '{print $1}' | grep -E '^pg-repack' | head -1)"
    if [ -n "$CAND" ]; then
      log "найден пакет: $CAND"
      $SUDO $PKG install -y "$CAND" && ok "установлен $CAND"
    else
      wr "готового пакета pg-repack-* нет. Дальше — сборка из исходников (см. команды выше)"
    fi
  fi
fi
hr
