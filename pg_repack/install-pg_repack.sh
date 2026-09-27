#!/usr/bin/env bash
#
# install-pg_repack.sh — автоматическая сборка и установка расширения pg_repack
#                       (automatic build & install of the pg_repack extension)
#
# Что делает скрипт / what the script does:
#   1) определяет ОС и менеджер пакетов / detects the OS and package manager
#   2) находит правильный pg_config (той же major-версии, что сервер) / finds the right pg_config
#   3) доустанавливает пакеты для сборки / installs build dependencies
#   4) скачивает исходники с GitHub / downloads the sources from GitHub
#   5) собирает: make / builds with make
#   6) устанавливает: make install (через sudo, если нужно) / installs
#   7) проверяет результат / verifies the result
#
# Примеры / examples:
#   ./install-pg_repack.sh
#   ./install-pg_repack.sh --pg-config /usr/lib/postgresql/16/bin/pg_config
#   ./install-pg_repack.sh --version 1.5.3 --dir /usr/local/src/pg_repack --no-deps
#   MAKE_ARGS="-j4" ./install-pg_repack.sh          # передать ключи в make
#
set -uo pipefail

REPACK_VERSION="${REPACK_VERSION:-1.5.3}"
BUILD_DIR="${BUILD_DIR:-/tmp/pg_repack-build}"
PG_CONFIG_BIN="${PG_CONFIG:-}"
SKIP_DEPS=0
MAKE_ARGS="${MAKE_ARGS:-}"
SUDO=""

C_OK="[ OK ]"
C_ERR="[FAIL]"
C_WARN="[WARN]"
C_INF="[ .. ]"

log()  { printf '%s %s\n' "$C_INF" "$*"; }
ok()   { printf '%s %s\n' "$C_OK"  "$*"; }
warn() { printf '%s %s\n' "$C_WARN" "$*"; }
die()  { printf '%s %s\n' "$C_ERR" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------"; }

usage() {
  cat <<'EOF'
Использование / usage:
  install-pg_repack.sh [ключи]

Ключи / options:
  -v, --version VER      версия pg_repack (по умолчанию 1.5.3)
      --pg-config PATH   полный путь к pg_config нужной версии
                         (по умолчанию ищется автоматически)
  -d, --dir DIR          каталог для загрузки и сборки (по умолчанию /tmp/pg_repack-build)
      --no-deps          не устанавливать пакеты ОС (только сборка)
  -h, --help             эта справка

Переменные окружения / environment:
  MAKE_ARGS="-j4"        дополнительные аргументы для make
  PG_CONFIG=/path        то же, что --pg-config
  REPACK_VERSION=1.5.3   то же, что --version
  BUILD_DIR=/tmp/xxx     то же, что --dir
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version)  REPACK_VERSION="${2:-}"; [ -n "$REPACK_VERSION" ] || die "не указана версия"; shift 2 ;;
    --pg-config)   PG_CONFIG_BIN="${2:-}"; [ -n "$PG_CONFIG_BIN" ] || die "не указан путь к pg_config"; shift 2 ;;
    -d|--dir)      BUILD_DIR="${2:-}";     [ -n "$BUILD_DIR" ] || die "не указан каталог сборки"; shift 2 ;;
    --no-deps)     SKIP_DEPS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "неизвестный ключ: $1 (см. --help)" ;;
  esac
done

[ "$(id -u)" -ne 0 ] || warn "скрипт запущен от root: собирать от root не рекомендуется, файлы будут принадлежать root"

# ---------------------------------------------------------------------------
# 1. Определяем менеджер пакетов / detect package manager
# ---------------------------------------------------------------------------
PKG=""
for p in apt-get dnf yum zypper apk pacman; do
  if command -v "$p" >/dev/null 2>&1; then PKG="$p"; break; fi
done

OS_NAME="unknown"
[ -r /etc/os-release ] && OS_NAME="$( . /etc/os-release; echo "${PRETTY_NAME:-$ID}" )"
log "ОС / OS: $OS_NAME   менеджер пакетов / package manager: ${PKG:-не найден}"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    warn "sudo не найден, а вы не root — установка пакетов и файлов может не сработать"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Ищем pg_config / find pg_config
# ---------------------------------------------------------------------------
find_pg_config() {
  local c best="" bestver=""
  if [ -n "$PG_CONFIG_BIN" ]; then
    [ -x "$PG_CONFIG_BIN" ] || die "не найден исполняемый файл: $PG_CONFIG_BIN"
    echo "$PG_CONFIG_BIN"; return 0
  fi
  if command -v pg_config >/dev/null 2>&1; then
    command -v pg_config; return 0
  fi
  # типовые места установки PostgreSQL
  for c in /usr/lib/postgresql/*/bin/pg_config \
           /usr/pgsql-*/bin/pg_config \
           /opt/pgpro/*/bin/pg_config \
           /usr/local/pgsql/bin/pg_config \
           /opt/postgresql*/bin/pg_config; do
    [ -x "$c" ] || continue
    local v; v="$("$c" --version 2>/dev/null | awk '{print $2}')"
    if [ -z "$bestver" ] || [ "$(printf '%s\n%s\n' "$bestver" "$v" | sort -V | tail -1)" = "$v" ]; then
      best="$c"; bestver="$v"
    fi
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

if ! PG_CONFIG_BIN="$(find_pg_config)"; then
  if [ "$SKIP_DEPS" = 1 ]; then
    die "pg_config не найден. Укажите путь явно, например: --pg-config /usr/lib/postgresql/<версия>/bin/pg_config"
  fi
  warn "pg_config не найден — попробуем установить dev-пакет PostgreSQL"
  PG_CONFIG_BIN=""
fi

PG_MAJOR=""
if [ -n "$PG_CONFIG_BIN" ]; then
  PG_VERSION_FULL="$("$PG_CONFIG_BIN" --version | awk '{print $2}')"
  PG_MAJOR="${PG_VERSION_FULL%%.*}"
  ok "pg_config: $PG_CONFIG_BIN (PostgreSQL $PG_VERSION_FULL)"
else
  PG_MAJOR="$(command -v psql >/dev/null 2>&1 && psql -tAc 'SHOW server_version' 2>/dev/null | cut -d. -f1 | tr -d ' ' || true)"
  [ -n "$PG_MAJOR" ] || die "не удалось определить major-версию PostgreSQL. Установите dev-пакет вручную и запустите скрипт с --pg-config"
  warn "буду ставить dev-пакет для PostgreSQL $PG_MAJOR"
fi

# предупреждение, если версия pg_config и сервера не совпадают
if command -v psql >/dev/null 2>&1; then
  SRV_VER="$(psql -tAc 'SHOW server_version' 2>/dev/null | tr -d ' ' || true)"
  if [ -n "${SRV_VER:-}" ] && [ -n "$PG_MAJOR" ] && [ "${SRV_VER%%.*}" != "$PG_MAJOR" ]; then
    warn "ВНИМАНИЕ: сервер PostgreSQL $SRV_VER, а pg_config от версии $PG_MAJOR."
    warn "Модуль надо собирать против ТОЙ ЖЕ major-версии, что сервер!"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Ставим пакеты для сборки / install build dependencies
# ---------------------------------------------------------------------------
# Имя пакета с pg_config / PGXS / заголовками зависит от того, чей это PostgreSQL:
#   PGDG или дистрибутив   -> postgresql18-devel
#   Postgres Pro для 1С    -> postgrespro-1c-18-devel
#   Postgres Pro Standard  -> postgrespro-std-18-devel
#   Postgres Pro Enterprise-> postgrespro-ent-18-devel
devel_pkg_name() {
  if [ -n "${PG_CONFIG_BIN:-}" ] && [ -n "${PG_MAJOR:-}" ]; then
    case "$PG_CONFIG_BIN" in
      /opt/pgpro/*/bin/pg_config)
        local ed="${PG_CONFIG_BIN#/opt/pgpro/}"; ed="${ed%%/*}"
        echo "postgrespro-${ed}-devel"; return 0
        ;;
    esac
  fi
  echo "postgresql${PG_MAJOR:-}-devel"
}

install_deps() {
  case "$PKG" in
    apt-get)
      $SUDO apt-get update
      $SUDO apt-get install -y build-essential zlib1g-dev curl tar
      if ! $SUDO apt-get install -y "postgresql-server-dev-$PG_MAJOR"; then
        warn "пакет postgresql-server-dev-$PG_MAJOR недоступен — пробую postgresql-server-dev-all"
        $SUDO apt-get install -y postgresql-server-dev-all
      fi
      ;;
    dnf|yum)
      # на RHEL/Alma/Rocky PostgreSQL обычно из репозитория PGDG, но бывает и Postgres Pro
      # (в т.ч. «для 1С»); readline/lz4/zstd/openssl/libcurl/numactl нужны потому, что сборка
      # PostgreSQL (особенно 18) перечисляет их в "pg_config --libs" (-lz -llz4 -lzstd -lssl -lcrypto -lcurl -lnuma)
      DEVEL_PKG="$(devel_pkg_name)"
      log "dev-пакет для сборки: $DEVEL_PKG"
      $SUDO "$PKG" install -y gcc make curl tar \
        readline-devel zlib-devel lz4-devel libzstd-devel openssl-devel \
        libcurl-devel numactl-devel \
        || warn "часть пакетов не установилась — возможно, у вас не PGDG-репозиторий"
      if ! $SUDO "$PKG" install -y "$DEVEL_PKG"; then
        warn "пакет $DEVEL_PKG недоступен — пробую postgresql$PG_MAJOR-devel"
        $SUDO "$PKG" install -y "postgresql$PG_MAJOR-devel" \
          || warn "и он недоступен. Поставьте dev-пакет вашего PostgreSQL вручную (подсказка: dnf provides '*/pg_config')"
      fi
      $SUDO "$PKG" -y install rpm-build rpmdevtools 2>/dev/null || true
      ;;
    zypper)
      $SUDO zypper --non-interactive install gcc make curl tar \
        "postgresql$PG_MAJOR-server-devel" \
        libopenssl-devel zlib-devel liblz4-devel libzstd-devel libcurl-devel
      ;;
    apk)
      $SUDO apk add --no-cache build-base zlib-dev curl tar "postgresql$PG_MAJOR-dev"
      ;;
    pacman)
      $SUDO pacman -Sy --noconfirm base-devel zlib curl tar postgresql-libs
      ;;
    *)
      warn "неизвестный менеджер пакетов: установите вручную gcc, make, zlib-devel и dev-пакет PostgreSQL"
      ;;
  esac
}

need_tools() {
  local miss=""
  for t in make gcc tar awk sed; do
    command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    miss="$miss curl/wget"
  fi
  [ -z "$miss" ] || { echo "$miss"; return 1; }
  return 0
}

if [ "$SKIP_DEPS" = 0 ]; then
  if ! need_tools >/dev/null 2>&1 || [ -z "$PG_CONFIG_BIN" ]; then
    hr; log "Устанавливаю пакеты для сборки / installing build dependencies"; hr
    install_deps
    # после установки ищем pg_config ещё раз
    if [ -z "$PG_CONFIG_BIN" ]; then
      PG_CONFIG_BIN="$(find_pg_config)" || die "pg_config всё ещё не найден — установите dev-пакет PostgreSQL вручную"
      PG_VERSION_FULL="$("$PG_CONFIG_BIN" --version | awk '{print $2}')"
      PG_MAJOR="${PG_VERSION_FULL%%.*}"
      ok "pg_config: $PG_CONFIG_BIN (PostgreSQL $PG_VERSION_FULL)"
    fi
  else
    log "Все инструменты сборки уже установлены — пакеты не трогаю (--no-deps отключит проверку)"
  fi
fi

MISSING="$(need_tools || true)"
[ -z "$MISSING" ] || die "не хватает инструментов:$MISSING — установите их и повторите запуск"
[ -n "$PG_CONFIG_BIN" ] || die "pg_config обязателен: --pg-config /usr/lib/postgresql/$PG_MAJOR/bin/pg_config"
ok "инструменты сборки на месте (make, gcc, tar, awk)"

# ---------------------------------------------------------------------------
# 4. Скачиваем исходники / download the sources
# ---------------------------------------------------------------------------
SRC_URL="https://github.com/reorg/pg_repack/archive/refs/tags/ver_${REPACK_VERSION}.tar.gz"
TARBALL="ver_${REPACK_VERSION}.tar.gz"
SRC_DIR="$BUILD_DIR/pg_repack-ver_${REPACK_VERSION}"

mkdir -p "$BUILD_DIR" || die "не могу создать каталог $BUILD_DIR"
rm -rf "$SRC_DIR"
[ -f "$BUILD_DIR/$TARBALL" ] && log "использую уже скачанный архив $BUILD_DIR/$TARBALL"

if [ ! -f "$BUILD_DIR/$TARBALL" ]; then
  hr; log "Скачиваю $SRC_URL"; hr
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$BUILD_DIR/$TARBALL" "$SRC_URL" || die "не удалось скачать исходники"
  else
    wget -O "$BUILD_DIR/$TARBALL" "$SRC_URL" || die "не удалось скачать исходники"
  fi
fi
ok "архив: $BUILD_DIR/$TARBALL ($(du -h "$BUILD_DIR/$TARBALL" | cut -f1))"

tar -xzf "$BUILD_DIR/$TARBALL" -C "$BUILD_DIR" || die "не удалось распаковать архив"
[ -d "$SRC_DIR" ] || die "после распаковки нет каталога $SRC_DIR"
ok "исходники распакованы: $SRC_DIR"

# ---------------------------------------------------------------------------
# 4b. LLVM / JIT-биткод / LLVM bitcode
#     В PGDG-сборках PostgreSQL 18 в PGXS прописано with_llvm = yes, и make тогда
#     вызывает clang и llvm-lto. Если их нет — сборка падает
#     ("/usr/bin/clang-19: No such file or directory"). Поэтому, если clang не
#     найден, добавляем with_llvm=no.
# ---------------------------------------------------------------------------
LLVM_ARG=""
PGXS_PATH="$("$PG_CONFIG_BIN" --pgxs)"
# Makefile.global лежит рядом с pgxs.mk: .../pgxs/src/makefiles/pgxs.mk -> .../pgxs/src/Makefile.global
PGXS_MAKEFILE=""
for cand in "$(dirname "$(dirname "$PGXS_PATH")")/Makefile.global" \
            "$(dirname "$PGXS_PATH")/Makefile.global" \
            "$(dirname "$(dirname "$(dirname "$PGXS_PATH")")")/Makefile.global"; do
  [ -r "$cand" ] && { PGXS_MAKEFILE="$cand"; break; }
done
if [ -r "$PGXS_MAKEFILE" ]; then
  WITH_LLVM="$(sed -n 's/^with_llvm[[:space:]]*=[[:space:]]*//p' "$PGXS_MAKEFILE" | head -1 | tr -d '[:space:]')"
  CLANG_BIN="$(sed -n 's/^CLANG[[:space:]]*=[[:space:]]*//p' "$PGXS_MAKEFILE" | head -1 | tr -d '[:space:]')"
  LLVM_BINPATH_DIR="$(sed -n 's/^LLVM_BINPATH[[:space:]]*=[[:space:]]*//p' "$PGXS_MAKEFILE" | head -1 | tr -d '[:space:]')"
  if [ "$WITH_LLVM" = "yes" ]; then
    HAVE_CLANG=0
    if [ -n "$CLANG_BIN" ] && [ -x "$CLANG_BIN" ]; then HAVE_CLANG=1
    elif command -v clang >/dev/null 2>&1; then HAVE_CLANG=1; fi
    HAVE_LTO=1
    if [ -n "$LLVM_BINPATH_DIR" ] && [ ! -x "$LLVM_BINPATH_DIR/llvm-lto" ]; then HAVE_LTO=0; fi
    if [ "$HAVE_CLANG" = 1 ] && [ "$HAVE_LTO" = 1 ]; then
      ok "LLVM включён в PGXS и clang найден (${CLANG_BIN:-clang}) — JIT-биткод будет собран"
    else
      LLVM_ARG="with_llvm=no"
      warn "PGXS требует LLVM (with_llvm=yes), но не найден ${CLANG_BIN:-clang}$([ "$HAVE_LTO" = 0 ] && echo " или ${LLVM_BINPATH_DIR}/llvm-lto")"
      warn "собираю с with_llvm=no — без JIT-биткода. Нужен биткод? Поставьте clang и llvm той же версии."
    fi
  fi
fi
MAKE_ARGS_EFF="${MAKE_ARGS:-} ${LLVM_ARG}"

# ---------------------------------------------------------------------------
# 5. Сборка / build
# ---------------------------------------------------------------------------
hr; log "Собираю: make PG_CONFIG=$PG_CONFIG_BIN ${MAKE_ARGS_EFF}"; hr
cd "$SRC_DIR" || die "не могу перейти в $SRC_DIR"
MAKE_LOG="$BUILD_DIR/make.log"
# shellcheck disable=SC2086
if ! make ${MAKE_ARGS_EFF} PG_CONFIG="$PG_CONFIG_BIN" >"$MAKE_LOG" 2>&1; then
  tail -n 25 "$MAKE_LOG" >&2
  die "ошибка сборки (полный лог: $MAKE_LOG). Подсказки: нужен dev-пакет PostgreSQL $PG_MAJOR (postgresql$PG_MAJOR-devel / postgresql-server-dev-$PG_MAJOR), zlib-devel/zlib1g-dev, а для PG18 ещё libcurl-devel и numactl-devel (в pg_config --libs есть -lcurl и -lnuma)"
fi
ok "сборка выполнена (лог: $MAKE_LOG)"

for f in bin/pg_repack lib/pg_repack.so lib/pg_repack.control "lib/pg_repack--${REPACK_VERSION}.sql"; do
  [ -f "$f" ] || die "не найден результат сборки: $f"
done
ok "получены файлы: bin/pg_repack, lib/pg_repack.so, lib/pg_repack.control, lib/pg_repack--${REPACK_VERSION}.sql"

# ---------------------------------------------------------------------------
# 6. Установка / install
# ---------------------------------------------------------------------------
hr; log "Устанавливаю: make install PG_CONFIG=$PG_CONFIG_BIN ${MAKE_ARGS_EFF}"; hr
INSTALL_LOG="$BUILD_DIR/make-install.log"
# shellcheck disable=SC2086
if ! $SUDO make ${MAKE_ARGS_EFF} PG_CONFIG="$PG_CONFIG_BIN" install >"$INSTALL_LOG" 2>&1; then
  tail -n 25 "$INSTALL_LOG" >&2
  die "ошибка установки (полный лог: $INSTALL_LOG)"
fi
ok "установка выполнена (лог: $INSTALL_LOG)"

# ---------------------------------------------------------------------------
# 7. Проверка / verify
# ---------------------------------------------------------------------------
BINDIR="$("$PG_CONFIG_BIN" --bindir)"
PKGLIBDIR="$("$PG_CONFIG_BIN" --pkglibdir)"
SHAREDIR="$("$PG_CONFIG_BIN" --sharedir)"
FAIL=0

check_file() {
  if [ -e "$1" ]; then ok "есть: $1"; else warn "НЕТ ФАЙЛА: $1"; FAIL=1; fi
}
check_file "$BINDIR/pg_repack"
check_file "$PKGLIBDIR/pg_repack.so"
check_file "$SHAREDIR/extension/pg_repack.control"
check_file "$SHAREDIR/extension/pg_repack--${REPACK_VERSION}.sql"

if [ -x "$BINDIR/pg_repack" ]; then
  # на всякий случай подкладываем в LD_LIBRARY_PATH каталог библиотек PostgreSQL (libpq)
  VOUT="$(LD_LIBRARY_PATH="$("$PG_CONFIG_BIN" --libdir):${LD_LIBRARY_PATH:-}" "$BINDIR/pg_repack" --version 2>&1)" || true
  case "$VOUT" in
    *"$REPACK_VERSION"*) ok "клиент отвечает: $VOUT" ;;
    *) warn "не удалось запустить клиент: $VOUT"
       warn "если это ошибка про libpq.so — добавьте $("$PG_CONFIG_BIN" --libdir) в LD_LIBRARY_PATH (или запускайте с этой переменной)" ;;
  esac
fi

hr
if [ "$FAIL" = 0 ]; then
  ok "pg_repack $REPACK_VERSION установлен"
else
  warn "не все файлы установились — проверьте вывод выше (правильный ли PG_CONFIG?)"
fi

cat <<EOF

Что делать дальше / next steps:
  1) включить расширение в базе (нужен суперпользователь):
       sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
     если расширение уже стояло:
       sudo -u postgres psql -d mydb -c "ALTER EXTENSION pg_repack UPDATE;"

  2) проверить:
       $BINDIR/pg_repack --version
       psql -d mydb -c "SELECT extname, extversion FROM pg_extension WHERE extname='pg_repack';"

  3) первый прогон:
       $BINDIR/pg_repack -d mydb --dry-run
       $BINDIR/pg_repack -d mydb -t myschema.mytable

  4) быстрый автотест:
       ./test-pg_repack.sh --dbname mydb --user postgres

Если $BINDIR не в PATH, добавьте:
       export PATH="$BINDIR:\$PATH"
EOF
[ "$FAIL" = 0 ] || exit 1
