#!/usr/bin/env bash
#
# test-pg_repack.sh — быстрая проверка работоспособности pg_repack
#                     (quick end-to-end smoke test for pg_repack)
#
# Что делает скрипт / what the script does:
#   1) находит клиент pg_repack и проверяет его версию / locates the client, checks its version
#   2) проверяет, включено ли расширение в базе (при необходимости включает) / checks the extension
#   3) создаёт тестовую таблицу, «раздувает» её (insert + delete) / creates and bloats a test table
#   4) запускает pg_repack и сверяет количество строк / runs pg_repack and compares row counts
#   5) печатает PASS/FAIL и убирает тестовую таблицу / prints PASS/FAIL and cleans up
#
# Примеры / examples:
#   ./test-pg_repack.sh --dbname mydb --user postgres
#   ./test-pg_repack.sh -d mydb -U postgres --host localhost --port 5433
#   ./test-pg_repack.sh -d mydb -U postgres --rows 500000 --keep
#
set -uo pipefail

DBNAME="${PGDATABASE:-postgres}"
DBUSER="${PGUSER:-}"
DBHOST=""
DBPORT=""
TABLE="pg_repack_selftest"
ROWS=200000
PG_CONFIG_BIN="${PG_CONFIG:-}"
KEEP=0

log()  { printf '[ .. ] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
err()  { printf '[FAIL] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*"; }
hr()   { printf '%s\n' "------------------------------------------------------------------"; }

usage() {
  cat <<'EOF'
Использование / usage:
  test-pg_repack.sh [ключи]

Ключи / options:
  -d, --dbname NAME    база данных (по умолчанию: $PGDATABASE или postgres)
  -U, --user NAME      пользователь (по умолчанию: как в psql/$PGUSER)
      --host HOST      хост или каталог сокета
  -p, --port PORT      порт
      --table NAME     имя тестовой таблицы (по умолчанию pg_repack_selftest)
      --rows N         сколько строк вставлять (по умолчанию 200000)
      --pg-config PATH путь к pg_config (иначе берётся из PATH)
      --keep           не удалять тестовую таблицу после проверки
  -h, --help           эта справка
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dbname)   DBNAME="${2:-}"; shift 2 ;;
    -U|--user)     DBUSER="${2:-}"; shift 2 ;;
    --host)        DBHOST="${2:-}"; shift 2 ;;
    -p|--port)     DBPORT="${2:-}"; shift 2 ;;
    --table)       TABLE="${2:-}"; shift 2 ;;
    --rows)        ROWS="${2:-}"; shift 2 ;;
    --pg-config)   PG_CONFIG_BIN="${2:-}"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "неизвестный ключ: $1 (см. --help)"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Находим pg_config и клиент pg_repack / find pg_config and the client
# ---------------------------------------------------------------------------
if [ -z "$PG_CONFIG_BIN" ]; then
  if command -v pg_config >/dev/null 2>&1; then
    PG_CONFIG_BIN="$(command -v pg_config)"
  else
    for c in /usr/lib/postgresql/*/bin/pg_config /usr/pgsql-*/bin/pg_config /usr/local/pgsql/bin/pg_config; do
      [ -x "$c" ] && PG_CONFIG_BIN="$c" && break
    done
  fi
fi
[ -n "$PG_CONFIG_BIN" ] || { err "pg_config не найден: укажите --pg-config /путь/pg_config"; exit 1; }

CLIENT="$("$PG_CONFIG_BIN" --bindir)/pg_repack"
if [ ! -x "$CLIENT" ]; then
  if command -v pg_repack >/dev/null 2>&1; then
    CLIENT="$(command -v pg_repack)"
  else
    err "клиент pg_repack не найден: $("$PG_CONFIG_BIN" --bindir)/pg_repack"
    err "сначала соберите и установите: make && sudo make install PG_CONFIG=$PG_CONFIG_BIN"
    exit 1
  fi
fi

PSQL="psql"
if ! command -v psql >/dev/null 2>&1; then
  # psql может отсутствовать в PATH (например /usr/pgsql-16/bin) — берём его рядом с pg_config
  if [ -x "$("$PG_CONFIG_BIN" --bindir)/psql" ]; then
    PSQL="$("$PG_CONFIG_BIN" --bindir)/psql"
  fi
fi
command -v "$PSQL" >/dev/null 2>&1 || { err "не найден psql (добавьте \$($PG_CONFIG_BIN --bindir) в PATH)"; exit 1; }

# аргументы подключения / connection arguments
CONN=(-d "$DBNAME")
[ -n "$DBUSER" ] && CONN+=(-U "$DBUSER")
[ -n "$DBHOST" ] && CONN+=(-h "$DBHOST")
[ -n "$DBPORT" ] && CONN+=(-p "$DBPORT")

log "клиент: $CLIENT"
CLIENT_VER="$("$CLIENT" --version 2>&1)" || { err "не удалось запустить клиент: $CLIENT_VER"; exit 1; }
ok "версия клиента: $CLIENT_VER"

SERVER_VER="$("$PSQL" "${CONN[@]}" -tAc "SHOW server_version" 2>&1)" || { err "нет подключения к базе $DBNAME: $SERVER_VER"; exit 1; }
ok "сервер PostgreSQL: $SERVER_VER, база: $DBNAME"

MAJOR_CLIENT="$("$PG_CONFIG_BIN" --version | awk '{print $2}' | cut -d. -f1)"
case "$SERVER_VER" in
  "$MAJOR_CLIENT"*) ok "major-версия pg_config и сервера совпадают ($MAJOR_CLIENT)" ;;
  *) warn "pg_config от версии $MAJOR_CLIENT, а сервер $SERVER_VER — если тест упадёт, пересоберите под нужную версию" ;;
esac

# ---------------------------------------------------------------------------
# 2. Проверяем расширение в базе / check the extension in the database
# ---------------------------------------------------------------------------
EXT_VER="$("$PSQL" "${CONN[@]}" -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_repack'" 2>/dev/null | tr -d ' ')"
if [ -z "$EXT_VER" ]; then
  warn "расширение pg_repack не включено в базе $DBNAME — пробую включить (CREATE EXTENSION)"
  if OUT="$("$PSQL" "${CONN[@]}" -c "CREATE EXTENSION pg_repack" 2>&1)"; then
    EXT_VER="$("$PSQL" "${CONN[@]}" -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_repack'" | tr -d ' ')"
    ok "расширение включено, версия $EXT_VER"
  else
    err "не удалось включить расширение: $OUT"
    err "включите вручную под суперпользователем: sudo -u postgres psql -d $DBNAME -c \"CREATE EXTENSION pg_repack;\""
    exit 1
  fi
else
  ok "расширение pg_repack уже включено, версия $EXT_VER"
fi

IS_SUPER="$("$PSQL" "${CONN[@]}" -tAc "SELECT usesuper FROM pg_user WHERE usename = current_user" | tr -d ' ')"
CLIENT_OPTS=()
if [ "$IS_SUPER" != "t" ]; then
  warn "пользователь не суперпользователь — запускаю клиент с -k (--no-superuser-check)"
  CLIENT_OPTS+=(-k)
fi

# ---------------------------------------------------------------------------
# 3. Создаём и «раздуваем» тестовую таблицу / create and bloat the test table
# ---------------------------------------------------------------------------
hr; log "Создаю тестовую таблицу $TABLE и раздуваю её ($ROWS строк)"; hr
"$PSQL" "${CONN[@]}" -v ON_ERROR_STOP=1 -q -c "
DROP TABLE IF EXISTS $TABLE;
CREATE TABLE $TABLE (id int PRIMARY KEY, val text);
INSERT INTO $TABLE (id, val) SELECT i, md5(i::text) FROM generate_series(1, $ROWS) i;
DELETE FROM $TABLE WHERE id % 2 = 0;
" || { err "не удалось подготовить тестовую таблицу"; exit 1; }

read_stats() {
  "$PSQL" "${CONN[@]}" -tAc "
    SELECT (SELECT count(*) FROM $TABLE) || '|' ||
           pg_size_pretty(pg_relation_size('$TABLE')) || '|' ||
           pg_size_pretty(pg_total_relation_size('$TABLE'))"
}
STATS_BEFORE="$(read_stats | tr -d ' ')"
ROWS_BEFORE="${STATS_BEFORE%%|*}"
ok "до репаковки: строк = $ROWS_BEFORE, размер таблицы = $(echo "$STATS_BEFORE" | cut -d'|' -f2), с индексами = $(echo "$STATS_BEFORE" | cut -d'|' -f3)"

# ---------------------------------------------------------------------------
# 4. Запускаем pg_repack / run pg_repack
# ---------------------------------------------------------------------------
hr; log "Запускаю: $CLIENT ${CLIENT_OPTS[*]} -d $DBNAME -t $TABLE"; hr
if ! REPACK_OUT="$("$CLIENT" "${CLIENT_OPTS[@]}" -d "$DBNAME" \
      ${DBUSER:+-U "$DBUSER"} ${DBHOST:+-h "$DBHOST"} ${DBPORT:+-p "$DBPORT"} \
      -t "$TABLE" 2>&1)"; then
  err "pg_repack завершился с ошибкой:"
  printf '%s\n' "$REPACK_OUT" >&2
  exit 1
fi
printf '%s\n' "$REPACK_OUT" | sed 's/^/       /'
ok "pg_repack выполнен без ошибок"

# ---------------------------------------------------------------------------
# 5. Проверяем результат / verify the result
# ---------------------------------------------------------------------------
STATS_AFTER="$(read_stats | tr -d ' ')"
ROWS_AFTER="${STATS_AFTER%%|*}"
ok "после репаковки: строк = $ROWS_AFTER, размер таблицы = $(echo "$STATS_AFTER" | cut -d'|' -f2), с индексами = $(echo "$STATS_AFTER" | cut -d'|' -f3)"

RC=0
if [ "$ROWS_BEFORE" = "$ROWS_AFTER" ]; then
  ok "количество строк совпало ($ROWS_AFTER)"
else
  err "количество строк изменилось: было $ROWS_BEFORE, стало $ROWS_AFTER"
  RC=1
fi

if [ "$KEEP" = 1 ]; then
  warn "тестовая таблица $TABLE оставлена (--keep)"
else
  "$PSQL" "${CONN[@]}" -q -c "DROP TABLE IF EXISTS $TABLE" && ok "тестовая таблица удалена"
fi

hr
if [ "$RC" = 0 ]; then
  ok "PASS: pg_repack $EXT_VER работает на базе $DBNAME"
else
  err "FAIL: см. сообщения выше"
fi
exit "$RC"
