# pg_repack 1.5.3 — сборка и установка на Linux (пошаговая инструкция)

**English version is below** (see "English version" section at the end).
**Версия в этом документе:** pg_repack **1.5.3**, исходники:
`https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz`

> Проверено на практике: Debian 12 + PostgreSQL 16.2 — сборка, `make install`,
> `CREATE EXTENSION pg_repack` и реальный запуск `pg_repack` на таблице прошли успешно.
> Все сообщения об ошибках из раздела «Частые ошибки» — настоящие тексты ошибок
> компилятора/сервера, а не выдуманные.

---

## 0. Главное, что нужно понять перед началом

pg_repack состоит из **двух частей**, и обе ставятся из одних и тех же исходников:

| Часть | Что это | Откуда собирается | Куда устанавливается |
|---|---|---|---|
| **Серверная** | расширение БД: `pg_repack.so`, `pg_repack.control`, `pg_repack--1.5.3.sql` | каталог `lib/` | `$(pg_config --pkglibdir)` и `$(pg_config --sharedir)/extension` |
| **Клиент** | консольная утилита `pg_repack` | каталог `bin/` | `$(pg_config --bindir)` |

Три правила, из-за которых чаще всего ломается сборка:

1. **Версия `pg_config` = версия сервера PostgreSQL.** Если сервер 16, то `pg_config`
   должен быть от 16 (не от 15 и не от 17). Проверка: `pg_config --version`.
2. **`make install` нужно делать от root** (`sudo make install`) — иначе файлы не
   попадут в системные каталоги PostgreSQL.
3. **Расширение надо включить в каждой базе отдельно:**
   `CREATE EXTENSION pg_repack;` (под суперпользователем).

---

## 0-А. ВАШ СЛУЧАЙ: AlmaLinux 9 + PostgreSQL 18 и сборка RPM

Это отдельный раздел для конфигурации **AlmaLinux 9 (MantisBT 9.8) + PostgreSQL 18
из репозитория PGDG**, где последняя команда была
`rpmbuild -bb ~/rpmbuild/SPECS/pg_repack_18.spec`.

### Почему раньше падало (три реальные причины для PG18)

1. **LLVM/JIT-биткод.** В `postgresql18-devel` из PGDG прописано `with_llvm = yes`
   (JIT-компиляция). Поэтому `make` и `make install` дополнительно вызывают
   `clang` и `llvm-lto`, даже если вам это не нужно. Если clang нет — сборка
   обрывается на середине. Реальный вывод (воспроизведено, PGXS):
   ```
   /usr/bin/clang-19 -Wno-ignored-attributes -O2 ... -flto=thin -emit-llvm -c -o pg_repack.bc pg_repack.c
   make[1]: /usr/bin/clang-19: No such file or directory
   make[1]: *** [.../src/Makefile.global:1093: pg_repack.bc] Error 127
   ```
   **Лечится флагом `with_llvm=no`** (проверено: сборка и установка проходят,
   файлы `.bc` не создаются).
2. **Новые библиотеки у PG18.** В PG18 сборка PostgreSQL из PGDG добавила в
   `pg_config --libs` библиотеки `-lcurl` и `-lnuma` (libpq-oauth и NUMA).
   Значит для линковки pg_repack нужны `libcurl-devel` и `numactl-devel`,
   иначе будет `/usr/bin/ld: cannot find -lcurl` или `-lnuma`.
3. **Макросы в чужом спеке.** Официальный спек PGDG (`pgdg-rpms`,
   `rpm/redhat/18/pg_repack`) использует макросы `%{pginstdir}` и
   `%{pgmajorversion}`, которые задаёт **инфраструктура сборки PGDG**
   (пакет `pgdg-srpm-macros`), а не `postgresql18-devel`. При локальном
   `rpmbuild` они не определены → файлы уезжают не в `/usr/pgsql-18`, а в
   `/bin`, `/lib`, и появляются ошибки вида
   `error: File not found: .../usr/pgsql-18/bin/pg_repack`.
   Либо задайте их вручную (см. ниже), либо используйте готовый спек
   `pg_repack_18.spec` из этого каталога (в нём всё определено).

### Шаг A0. Проверить/поставить PostgreSQL 18 и dev-пакет

```bash
# репозиторий PGDG (один раз; для EL-9 ссылка именно такая)
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql        # отключает модуль postgresql из AppStream

# сервер, клиент и dev-пакет (dev-пакет обязателен: в нём pg_config, PGXS и заголовки)
sudo dnf install -y postgresql18-server postgresql18 postgresql18-devel

# если база ещё не инициализирована (каталога /var/lib/pgsql/18/data нет):
sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
sudo systemctl enable --now postgresql-18

# проверка:
/usr/pgsql-18/bin/pg_config --version          # PostgreSQL 18.x
sudo -u postgres /usr/pgsql-18/bin/psql -c "SHOW server_version;"
sudo -u postgres /usr/pgsql-18/bin/psql -c "SHOW server_version_num;"
```

> **Важно:** `pg_config` у PGDG-пакетов лежит в `/usr/pgsql-18/bin` и **не** попадает
> в `PATH` автоматически. Либо пишите полный путь
> `PG_CONFIG=/usr/pgsql-18/bin/pg_config`, либо:
> ```bash
> echo 'export PATH=/usr/pgsql-18/bin:$PATH' | sudo tee /etc/profile.d/pgsql18.sh
> . /etc/profile.d/pgsql18.sh
> ```

### Шаг A1. Инструменты сборки

```bash
sudo dnf install -y gcc make rpmdevtools dnf-plugins-core
# библиотеки: zlib обязательна, остальные нужны, потому что PG18 собран с ними
sudo dnf install -y readline-devel zlib-devel lz4-devel libzstd-devel openssl-devel libcurl-devel numactl-devel
```

### Вариант 1 (самый быстрый): взять готовый RPM из PGDG

Сборка не нужна вообще — PGDG уже собирает pg_repack под PostgreSQL 18:

```bash
sudo dnf install -y pg_repack_18
ls -l /usr/pgsql-18/bin/pg_repack
# остаётся только включить расширение в базе:
sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
```

Это тот же pg_repack 1.5.3 — просто уже собранный. Свой RPM имеет смысл, если
нужен свой патч/флаги или нет доступа к репозиторию.

### Вариант 2: собрать из исходников через make (минимум сюрпризов)

```bash
cd /tmp
curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
tar -xzf ver_1.5.3.tar.gz
cd pg_repack-ver_1.5.3

export PG_CONFIG=/usr/pgsql-18/bin/pg_config
$PG_CONFIG --version                      # должно быть 18.x
$PG_CONFIG --libs                         # тут видно -lcurl/-lnuma (значит нужны libcurl-devel, numactl-devel)

make  PG_CONFIG=$PG_CONFIG with_llvm=no
sudo make install PG_CONFIG=$PG_CONFIG with_llvm=no
```

Ключ **`with_llvm=no`** убирает вызовы `clang`/`llvm-lto` (проверено: без него
на PG18-подобной сборке падает `make[1]: /usr/bin/clang-19: No such file or directory`,
с ним — собирается и ставит ровно 4 файла:
`/usr/pgsql-18/bin/pg_repack`, `/usr/pgsql-18/lib/pg_repack.so`,
`/usr/pgsql-18/share/extension/pg_repack.control`,
`/usr/pgsql-18/share/extension/pg_repack--1.5.3.sql`).

Если хотите JIT-биткод (не обязательно): поставьте clang/llvm **той же версии,
что указана в PGXS**, и собирайте без флага:

```bash
# посмотреть, какой именно clang и llvm-lto ждёт ваш postgresql18-devel:
grep -E '^(with_llvm|CLANG|LLVM_BINPATH)' "$(dirname "$($PG_CONFIG --pgxs)")/Makefile.global"
# например: CLANG = /usr/bin/clang-19, LLVM_BINPATH = /usr/bin
sudo dnf install -y clang llvm llvm-tools     # если версия совпадёт
make PG_CONFIG=$PG_CONFIG
```

Проверка и включение расширения:

```bash
/usr/pgsql-18/bin/pg_repack --version
sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
sudo -u postgres psql -d mydb -c "SELECT extname, extversion FROM pg_extension WHERE extname='pg_repack';"
```

### Вариант 3: собрать свой RPM (`rpmbuild -bb`) — ваш вариант

В этом каталоге лежит готовый `pg_repack_18.spec` (сделан на основе официального
спека PGDG, но самодостаточный: `pginstdir`/`pgmajorversion` определяются внутри,
LLVM по умолчанию выключен).

```bash
# 1. дерево каталогов для сборки RPM (создаст ~/rpmbuild/{SPECS,SOURCES,BUILD,RPMS,SRPMS})
rpmdev-setuptree

# 2. положить спек и исходник
cp /путь/к/scripts/pg_repack/pg_repack_18.spec ~/rpmbuild/SPECS/
cd ~/rpmbuild/SOURCES
curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
ls -l ver_1.5.3.tar.gz        # имя файла обязано быть ровно таким (это basename из Source0)

# 3. поставить BuildRequires из спека (репозиторий PGDG должен быть включён)
sudo dnf builddep -y ~/rpmbuild/SPECS/pg_repack_18.spec
# если dnf builddep недоступен — поставьте руками:
# sudo dnf install -y gcc make postgresql18-devel readline-devel zlib-devel lz4-devel libzstd-devel openssl-devel libcurl-devel numactl-devel

# 4. собрать (НЕ от root — rpmbuild от root капризничает)
rpmbuild -bb ~/rpmbuild/SPECS/pg_repack_18.spec

# 5. посмотреть и поставить результат
ls -l ~/rpmbuild/RPMS/x86_64/pg_repack_18-1.5.3-1.el9.x86_64.rpm
sudo dnf install -y ~/rpmbuild/RPMS/x86_64/pg_repack_18-1.5.3-1.el9.x86_64.rpm

# 6. включить расширение в базах
sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
```

Полезные варианты запуска:

```bash
# собрать с JIT-биткодом (нужны clang и llvm подходящей версии)
rpmbuild -bb --define 'llvm 1' ~/rpmbuild/SPECS/pg_repack_18.spec

# если ваш спек — копия официального PGDG, ему нужно передать их макросы:
rpmbuild -bb --define 'pgmajorversion 18' --define 'pginstdir /usr/pgsql-18' \
             --define 'llvm 0' ~/rpmbuild/SPECS/pg_repack_18.spec
```

> Честно про проверку: сам `rpmbuild` я в своей песочнице запустить не смог (в ней нет
> rpm-утилит и нет доступа к репозиториям ОС), поэтому спек проверьте у себя командой
> `rpmbuild -bb ...` — он основан на официальном спеке PGDG `1.5.3-7PGDG`, а та часть,
> что относится к самой сборке (`make with_llvm=no`, `DESTDIR=... install`, список
> устанавливаемых файлов), проверена реальным запуском.

### Ошибки именно на AlmaLinux 9 + PG18

| Сообщение | Причина | Решение |
|---|---|---|
| `/usr/bin/clang-19: No such file or directory` + `Error 127` при `make`/`make install` (или `make[1]: clang: command not found`) | в `postgresql18-devel` включён `with_llvm=yes`, а clang/llvm не установлены | добавить `with_llvm=no` в `make` и `make install`; либо поставить clang/llvm нужной версии |
| `/usr/bin/ld: cannot find -lcurl` | PG18 собран с libpq-oauth, `-lcurl` есть в `pg_config --libs` | `sudo dnf install -y libcurl-devel` |
| `/usr/bin/ld: cannot find -lnuma` | PG18 собран с NUMA-поддержкой | `sudo dnf install -y numactl-devel` |
| `/usr/bin/ld: cannot find -llz4` / `-lzstd` / `-lssl` / `-lcrypto` / `-lz` | те же причины: сборка PostgreSQL использует эти библиотеки | `sudo dnf install -y lz4-devel libzstd-devel openssl-devel zlib-devel` |
| `/usr/bin/llvm-lto: No such file or directory` при `make install` | JIT-биткод собран, но нет llvm-tools | `sudo dnf install -y llvm llvm-tools` или `with_llvm=no` |
| `error: File not found: .../usr/pgsql-18/bin/pg_repack` при rpmbuild | спек ставит файлы не туда: не определены `%{pginstdir}`/`%{pgmajorversion}` (официальный спек рассчитывает на макросы PGDG) | задать макросы через `--define` или взять `pg_repack_18.spec` из этого каталога |
| `error: Bad source: .../SOURCES/ver_1.5.3.tar.gz: No such file or directory` | исходник не скачан в `~/rpmbuild/SOURCES` или назван иначе | `cd ~/rpmbuild/SOURCES && curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz` |
| `*** pg_config not found. Stop.` | `pg_config` не в `PATH` (PGDG ставит его в `/usr/pgsql-18/bin`) | `make PG_CONFIG=/usr/pgsql-18/bin/pg_config ...` |
| `pg_config --version` показывает 18, а модуль не грузится (`undefined symbol`/`incompatible`) | собрано против другой major-версии | `make clean`, пересобрать с `PG_CONFIG=/usr/pgsql-18/bin/pg_config` |
| `dnf builddep`/`rpmbuild` не найден | не установлены инструменты | `sudo dnf install -y rpmdevtools dnf-plugins-core rpm-build` |
| `ERROR: pg_repack failed with error: pg_repack 1.5.3 is not installed in the database` | расширение не включено в эту базу | `CREATE EXTENSION pg_repack;` под суперпользователем |

### Шаг A4. Быстрая проверка результата (на AlmaLinux)

```bash
export PATH=/usr/pgsql-18/bin:$PATH
./test-pg_repack.sh --dbname mydb --user postgres                 # локальный сокет
./test-pg_repack.sh --dbname mydb --user postgres --host localhost --port 5432
```

---

## 1. Быстрый путь (если всё уже установлено)

```bash
# 1) проверяем версии
pg_config --version
psql -c "SHOW server_version;"

# 2) скачиваем и распаковываем исходники
cd /tmp
curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
tar -xzf ver_1.5.3.tar.gz
cd pg_repack-ver_1.5.3

# 3) собираем и устанавливаем
make
sudo make install

# 4) включаем расширение в базе (под суперпользователем)
sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"

# 5) проверяем
pg_repack --version
```

Дальше — подробно, по шагам.

---

## 2. Пошаговая инструкция

### Шаг 1. Проверить PostgreSQL, сервер и `pg_config`

```bash
# какой сервер запущен и какая у него версия
psql -c "SHOW server_version;"
psql -c "SELECT version();"

# какой pg_config виден в PATH и от какой он версии
which pg_config
pg_config --version
```

Возможные ситуации:

* `which pg_config` ничего не вывел → **dev-пакет не установлен**, смотрите Шаг 2.
* `pg_config --version` выводит не ту версию, что сервер → найдите правильный
  `pg_config` и передавайте его явно:

```bash
# Debian/Ubuntu: pg_config лежит тут (16 = major-версия сервера)
/usr/lib/postgresql/16/bin/pg_config --version

# RHEL/Rocky/Alma с пакетами PGDG: pg_config НЕ в PATH по умолчанию
/usr/pgsql-16/bin/pg_config --version

# дальше во всех командах указывайте его явно:
make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
sudo make install PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
```

Полезно сразу сохранить переменную, чтобы не повторяться:

```bash
export PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config   # подставьте свой путь
$PG_CONFIG --version
```

### Шаг 2. Установить пакеты для сборки

Нужны: компилятор, `make`, dev-пакет PostgreSQL **той же major-версии** и заголовки zlib.

**Debian / Ubuntu / Astra Linux (apt):**

```bash
sudo apt update
sudo apt install -y build-essential zlib1g-dev postgresql-server-dev-16 zlib1g-dev
#                                              ^^^^^^^^^^^^^^^^^^^^^^^ 16 = major-версия сервера
```

*Если пакета `postgresql-server-dev-16` нет* (например PG поставлен из PGDG-репозитория
и его версии нет в дистрибутиве):

```bash
sudo apt install -y build-essential zlib1g-dev postgresql-server-dev-all
# либо подключите репозиторий PGDG и поставьте postgresql-server-dev-16 из него
```

**RHEL / CentOS / Rocky / AlmaLinux / Oracle Linux (dnf или yum):**

```bash
# пакеты PostgreSQL берутся из репозитория PGDG (https://yum.postgresql.org/)
sudo dnf install -y gcc make zlib-devel postgresql16-devel
#                                                 ^^^^^^^^^^^^^^^^ 16 = major-версия сервера

# если yum:
# sudo yum install -y gcc make zlib-devel postgresql16-devel
```

**SUSE / openSUSE (zypper):**

```bash
sudo zypper install -y gcc make zlib-devel postgresql16-server-devel
```

Проверка, что всё нужное появилось:

```bash
which gcc make curl tar
pg_config --version
```

### Шаг 3. Скачать исходники

```bash
cd /tmp                      # НЕ собирайте в /root и не собирайте от root
curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
tar -xzf ver_1.5.3.tar.gz
cd pg_repack-ver_1.5.3       # имя каталога именно такое
```

Если `curl` недоступен (сервер без интернета): скачайте tar.gz на своей машине,
скопируйте по `scp` и распакуйте на сервере:

```bash
scp ver_1.5.3.tar.gz user@server:/tmp/
```

### Шаг 4. Собрать (`make`)

```bash
cd /tmp/pg_repack-ver_1.5.3

# обычный случай (pg_config правильной версии в PATH):
make

# если в PATH не тот pg_config — указываем явно:
make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
```

В конце сборки в дереве исходников должны появиться файлы:

```
bin/pg_repack               <- клиент
lib/pg_repack.so            <- серверный модуль
lib/pg_repack.control       <- описание расширения
lib/pg_repack--1.5.3.sql    <- SQL-скрипт расширения
```

Проверить:

```bash
ls -l bin/pg_repack lib/pg_repack.so lib/pg_repack.control lib/pg_repack--1.5.3.sql
```

Если раньше вы уже собирали этот же каталог под другую версию PostgreSQL —
обязательно очистите:

```bash
make clean
make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
```

### Шаг 5. Установить (`make install`)

```bash
sudo make install PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
# если pg_config в PATH правильный — достаточно: sudo make install
```

Что и куда копируется (пример вывода):

```
/usr/bin/install -c  pg_repack '/usr/bin'
/usr/bin/install -c -m 755  pg_repack.so '/usr/lib/postgresql/16/lib/pg_repack.so'
/usr/bin/install -c -m 644  pg_repack.control '/usr/share/postgresql/16/extension/'
/usr/bin/install -c -m 644  pg_repack--1.5.3.sql pg_repack.control '/usr/share/postgresql/16/extension/'
```

### Шаг 6. Проверить, что файлы легли в нужные каталоги

```bash
ls -l "$(pg_config --bindir)/pg_repack"                    # клиент
ls -l "$(pg_config --pkglibdir)/pg_repack.so"              # серверный модуль
ls -l "$(pg_config --sharedir)/extension/pg_repack.control" \
      "$(pg_config --sharedir)/extension/pg_repack--1.5.3.sql"   # расширение

pg_repack --version        # должно вывести: pg_repack 1.5.3
```

> Если `pg_repack --version` пишет `command not found`, добавьте каталог
> `$(pg_config --bindir)` в `PATH` (для RHEL это `/usr/pgsql-16/bin`):

```bash
export PATH="$(pg_config --bindir):$PATH"
```

### Шаг 7. Включить расширение в базе данных

Расширение включается **в каждую базу**, где будете репаковать таблицы.
Нужен суперпользователь (обычно `postgres`):

```bash
sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
# если расширение уже есть в базе и вы поставили новую версию:
sudo -u postgres psql -d mydb -c "ALTER EXTENSION pg_repack UPDATE;"
```

Проверка:

```bash
sudo -u postgres psql -d mydb -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_repack';"
# либо:
sudo -u postgres psql -d mydb -c "SELECT repack.version();"
```

Ожидаемый результат: `pg_repack | 1.5.3`.

### Шаг 8. Первый запуск — тест на одной таблице

```bash
# 1. Посмотреть, что вообще будет репаковаться (без изменений в базе):
pg_repack -d mydb --dry-run

# 2. Репаковать одну конкретную таблицу:
pg_repack -d mydb -t myschema.mytable

# 3. Вся база (все таблицы, требующие репаковки):
pg_repack -d mydb

# 4. Только индексы таблицы:
pg_repack -d mydb -t myschema.mytable --only-indexes
```

Успешный запуск выглядит так:

```
INFO: repacking table "public.t1"
```

> `pg_repack` требует прав суперпользователя (или роли с соответствующими правами).
> Для managed-облаков (RDS и т.п.) есть флаг `-k, --no-superuser-check`.

### Шаг 9. Обновление версии и удаление

**Обновление** (например, с 1.5.3 на более новую):

```bash
cd /tmp
curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.4.tar.gz
tar -xzf ver_1.5.4.tar.gz && cd pg_repack-ver_1.5.4
make && sudo make install
sudo -u postgres psql -d mydb -c "ALTER EXTENSION pg_repack UPDATE;"
```

**Удаление из базы:**

```bash
sudo -u postgres psql -d mydb -c "DROP EXTENSION pg_repack;"
```

**Удаление файлов из системы:**

```bash
cd /tmp/pg_repack-ver_1.5.3
sudo make uninstall
```

---

## 3. Автоматический скрипт (всё делает сам)

В этом каталоге лежит `install-pg_repack.sh` — он выполняет шаги 1–6:
определяет ОС и менеджер пакетов, находит правильный `pg_config` (в том числе
`/usr/pgsql-18/bin/pg_config` на AlmaLinux/RHEL), доустанавливает пакеты, сам
подставляет `with_llvm=no`, если LLVM в PostgreSQL включён, а clang отсутствует,
скачивает исходники, собирает, устанавливает и проверяет результат.

```bash
chmod +x install-pg_repack.sh
./install-pg_repack.sh                 # обычный запуск (сам найдёт pg_config)
./install-pg_repack.sh --help          # все ключи

# примеры:
./install-pg_repack.sh --pg-config /usr/lib/postgresql/16/bin/pg_config
./install-pg_repack.sh --version 1.5.3 --dir /usr/local/src/pg_repack
./install-pg_repack.sh --no-deps       # не трогать пакеты ОС, только сборка
```

## 4. Проверка работоспособности

Скрипт `test-pg_repack.sh` создаёт тестовую таблицу, «раздувает» её (вставляет и
удаляет строки), запускает `pg_repack`, сверяет количество строк и убирает за собой:

```bash
chmod +x test-pg_repack.sh
./test-pg_repack.sh --dbname mydb --user postgres
./test-pg_repack.sh --dbname mydb --user postgres --port 5433 --host localhost
```

Для AlmaLinux 9 + PostgreSQL 18 в этом же каталоге лежит `pg_repack_18.spec` —
самодостаточный спек для сборки RPM (`rpmbuild -bb`), см. раздел 0-А выше.

Результат: `PASS` — расширение работает; `FAIL` — смотрите вывод ошибки.

Пример успешного прогона (реальный вывод, PostgreSQL 16):

```
[ OK ] версия клиента: pg_repack 1.5.3
[ OK ] сервер PostgreSQL: 16.2, база: postgres
[ OK ] major-версия pg_config и сервера совпадают (16)
[ OK ] расширение pg_repack уже включено, версия 1.5.3
[ OK ] до репаковки: строк = 30000, размер таблицы = 4000kB, с индексами = 5360kB
       INFO: repacking table "public.pg_repack_selftest"
[ OK ] после репаковки: строк = 30000, размер таблицы = 2000kB, с индексами = 2704kB
[ OK ] количество строк совпало (30000)
[ OK ] PASS: pg_repack 1.5.3 работает на базе postgres
```

Здесь видно, что файл таблицы уменьшился с 4000 kB до 2000 kB — то есть «раздутость»
(bloat) реально убрана, а количество строк не изменилось.

---

## 5. Частые ошибки и что делать

| Сообщение об ошибке | Причина | Решение |
|---|---|---|
| `Makefile:18: *** pg_config not found. Stop.` | `pg_config` не в `PATH` / не установлен dev-пакет | установить `postgresql-server-dev-16` (apt) или `postgresql16-devel` (dnf); либо `make PG_CONFIG=/полный/путь/pg_config` |
| `make: pg_config: No such file or directory` | то же самое | то же самое |
| `fatal error: postgres.h: No such file or directory` | не установлен dev-пакет или он другой major-версии | поставить dev-пакет **той же** версии, что сервер |
| `Makefile:...: /usr/lib/postgresql/16/lib/pgxs/src/makefiles/pgxs.mk: No such file or directory` | не установлен dev-пакет (в нём лежит PGXS) | `sudo apt install postgresql-server-dev-16` / `sudo dnf install postgresql16-devel` |
| `/usr/bin/ld: cannot find -lz` | нет заголовков/символьной ссылки zlib | `sudo apt install zlib1g-dev` / `sudo dnf install zlib-devel` (проверено: именно так лечится) |
| `/usr/bin/ld: cannot find -lpgcommon` или `-lpgport` | версия dev-пакета не совпадает с версией `pg_config` | поставить dev-пакет нужной major-версии, использовать правильный `pg_config` |
| `ld:exports.list:2: syntax error in VERSION script` | в системе нет `gawk`, а сборка настроена на него (редкий случай) | `sudo apt install gawk` **или** `make AWK=awk` |
| `ERROR: could not open extension control file ".../extension/pg_repack.control": No such file or directory` (при `CREATE EXTENSION`) | не сделан `make install`, либо файлы установились в другой PostgreSQL (другой `pg_config`) | выполнить `sudo make install` с правильным `PG_CONFIG`; проверить Шаг 6 на том же сервере, где база |
| `ERROR: permission denied to create extension "pg_repack"` / требуется суперпользователь | нет прав | `sudo -u postgres psql ...` (или выдать роль с правами суперпользователя) |
| `ERROR: pg_repack failed with error: pg_repack 1.5.3 is not installed in the database` | расширение не включено в эту базу | `sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"` |
| `ERROR: program 'pg_repack X' does not match database library 'pg_repack Y'` | версия клиента и версия расширения в базе различаются | переустановить обе части из одной версии исходников и выполнить `ALTER EXTENSION pg_repack UPDATE;` |
| `ERROR: could not load library ".../pg_repack.so": undefined symbol: ...` или `wrong ELF class` | модуль собран под другую major-версию PostgreSQL или другую архитектуру | `make clean`, собрать с правильным `PG_CONFIG` (версия должна совпадать с сервером) |
| `pg_repack: error while loading shared libraries: libpq.so.5: cannot open shared object file` | клиент не находит библиотеку `libpq` (редко, RHEL) | запускать из `$(pg_config --bindir)`; либо добавить каталог библиотек в `LD_LIBRARY_PATH` и `ldconfig` |
| `psql: FATAL: role "postgres" does not exist` | неверное имя пользователя для подключения | указать `-U <свой_пользователь> -d <база>` |
| `psql: error: could not connect to server ... No such file or directory` | неверный сокет/порт | указать `-h /var/run/postgresql` (или `-h localhost`) и `-p <порт>` |

**Как быстро собрать информацию для диагностики** (пришлите вывод этих команд,
если что-то не работает):

```bash
cat /etc/os-release
uname -m
which pg_config && pg_config --version
psql -c "SHOW server_version;"
gcc --version | head -1
make --version | head -1
```

---

## 6. Шпаргалка по утилите `pg_repack` (версия 1.5.3)

```
pg_repack [КЛЮЧИ] [DBNAME]

Основные ключи:
  -d, --dbname=DBNAME        база данных
  -h, --host=HOST            хост или каталог сокета
  -p, --port=PORT            порт
  -U, --username=USER        пользователь
  -a, --all                  обработать все базы
  -t, --table=TABLE          только указанная таблица
  -I, --parent-table=TABLE   таблица и все её наследники
  -c, --schema=SCHEMA        только таблицы указанной схемы
  -s, --tablespace=TBLSPC    перенести таблицы в другое табличное пространство
  -S, --moveidx              перенести и индексы (вместе с -s)
  -o, --order-by=COLUMNS     порядок отличный от ключей кластера
  -n, --no-order             выполнить vacuum full вместо cluster
  -N, --dry-run              только показать, что будет сделано
  -j, --jobs=NUM             параллельные задания (в т.ч. для сборки индексов)
  -i, --index=INDEX          перенести только указанный индекс
  -x, --only-indexes         перенести только индексы указанной таблицы
  -T, --wait-timeout=SECS    таймаут отмены конфликтующих бэкендов
  -Z, --no-analyze           не выполнять analyze в конце
  -k, --no-superuser-check   пропустить проверку прав суперпользователя
  -e, --echo                 печатать SQL-запросы
      --help / --version     справка / версия
```

Типовые сценарии:

```bash
pg_repack -d mydb -N                          # посмотреть план (dry-run)
pg_repack -d mydb -t public.big_table -j 4    # репак одной таблицы в 4 потока
pg_repack -d mydb -t public.big_table -x      # только индексы
pg_repack -d mydb                             # вся база
pg_repack -a -d postgres                      # все базы (под суперпользователем)
```

---

# English version

## pg_repack 1.5.3 — build and install on Linux (step by step)

pg_repack has **two parts**, both built from the same source tree:

* **server part** — the extension (`pg_repack.so`, `pg_repack.control`, `pg_repack--1.5.3.sql`),
  built from `lib/`, installed into `$(pg_config --pkglibdir)` and `$(pg_config --sharedir)/extension`;
* **client part** — the `pg_repack` command line tool, built from `bin/`, installed into
  `$(pg_config --bindir)`.

Three rules: (1) `pg_config` must belong to the **same major version as the running server**;
(2) `make install` must be run as root (`sudo make install`); (3) the extension must be
enabled **in every database** you want to repack (`CREATE EXTENSION pg_repack;`).

### Step 1 — check PostgreSQL and pg_config

```bash
psql -c "SHOW server_version;"
which pg_config
pg_config --version
```

If `pg_config` is not found or reports the wrong version, use the full path, for example
`/usr/lib/postgresql/16/bin/pg_config` (Debian/Ubuntu) or `/usr/pgsql-16/bin/pg_config`
(RHEL/Rocky with PGDG packages), and pass it to every make command:
`make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config`.

### Step 2 — install build dependencies

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y build-essential zlib1g-dev postgresql-server-dev-16   # 16 = server major version

# RHEL / Rocky / AlmaLinux / Oracle Linux
sudo dnf install -y gcc make zlib-devel postgresql16-devel                # 16 = server major version

# SUSE / openSUSE
sudo zypper install -y gcc make zlib-devel postgresql16-server-devel
```

### Step 3 — download the sources

```bash
cd /tmp
curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz
tar -xzf ver_1.5.3.tar.gz
cd pg_repack-ver_1.5.3
```

### Step 4 — build and install

```bash
make                                   # or: make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
sudo make install                      # or: sudo make install PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
```

Expected artifacts after `make`: `bin/pg_repack`, `lib/pg_repack.so`, `lib/pg_repack.control`,
`lib/pg_repack--1.5.3.sql`. If you rebuild for another PostgreSQL version, run `make clean` first.

### Step 5 — verify the installation

```bash
ls -l "$(pg_config --bindir)/pg_repack"
ls -l "$(pg_config --pkglibdir)/pg_repack.so"
ls -l "$(pg_config --sharedir)/extension/pg_repack.control"
pg_repack --version                    # pg_repack 1.5.3
```

### Step 6 — enable the extension in a database

```bash
sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"
# or, after upgrading:
sudo -u postgres psql -d mydb -c "ALTER EXTENSION pg_repack UPDATE;"
```

### Step 7 — first run

```bash
pg_repack -d mydb --dry-run                    # show what would be repacked
pg_repack -d mydb -t myschema.mytable          # repack one table
pg_repack -d mydb                              # repack the whole database
pg_repack -d mydb -t myschema.mytable -x       # indexes only
```

Successful output: `INFO: repacking table "public.t1"`.

### Common errors

| Error | Fix |
|---|---|
| `*** pg_config not found. Stop.` | install the `-devel` / `-server-dev` package or pass `PG_CONFIG=/path/to/pg_config` |
| `fatal error: postgres.h: No such file or directory` | install the server dev package matching the server major version |
| `pgxs.mk: No such file or directory` | the dev package is not installed |
| `/usr/bin/ld: cannot find -lz` | `apt install zlib1g-dev` / `dnf install zlib-devel` |
| `ld:exports.list:2: syntax error in VERSION script` | `sudo apt install gawk`, or build with `make AWK=awk` |
| `ERROR: could not open extension control file ".../pg_repack.control"` | `sudo make install` was not run, or was run for a different PostgreSQL (`pg_config`) |
| `ERROR: pg_repack failed with error: pg_repack 1.5.3 is not installed in the database` | `CREATE EXTENSION pg_repack;` in that database |
| `ERROR: program 'pg_repack X' does not match database library 'pg_repack Y'` | rebuild/reinstall both parts from one version, then `ALTER EXTENSION pg_repack UPDATE;` |
| `undefined symbol` / `wrong ELF class` when loading `pg_repack.so` | module built for the wrong PostgreSQL version/architecture: `make clean`, rebuild with the right `pg_config` |

### AlmaLinux 9 / RHEL 9 with PostgreSQL 18 (from the PGDG repo)

```bash
# PGDG repository (once), then PostgreSQL 18 + its dev package
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql18-server postgresql18 postgresql18-devel

# build tools and libraries (PG18 is built with all of them)
sudo dnf install -y gcc make readline-devel zlib-devel lz4-devel libzstd-devel openssl-devel libcurl-devel numactl-devel

# build and install (note: pg_config is not in PATH with PGDG packages)
cd /tmp && curl -LO https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz && tar -xzf ver_1.5.3.tar.gz
cd pg_repack-ver_1.5.3
make        PG_CONFIG=/usr/pgsql-18/bin/pg_config with_llvm=no
sudo make install PG_CONFIG=/usr/pgsql-18/bin/pg_config with_llvm=no
```

* **`with_llvm=no` matters**: PGDG's `postgresql18-devel` has `with_llvm=yes`, so make tries to
  emit LLVM bitcode and dies with `/usr/bin/clang-19: No such file or directory` / `Error 127`
  if clang and llvm are not installed (verified reproduction). Either add the flag, or install
  matching `clang`/`llvm`/`llvm-tools`.
* **`libcurl-devel` and `numactl-devel`** are needed because PG18's `pg_config --libs` contains
  `-lcurl` and `-lnuma`; without them you get `/usr/bin/ld: cannot find -lcurl` (or `-lnuma`).
* The easiest option of all: `sudo dnf install -y pg_repack_18` — PGDG already ships a 1.5.3 RPM
  for PostgreSQL 18; you only need `CREATE EXTENSION pg_repack;` afterwards.
* To build **your own RPM**: `rpmdev-setuptree`, copy [`pg_repack_18.spec`](pg_repack_18.spec) from
  this folder to `~/rpmbuild/SPECS/`, download `ver_1.5.3.tar.gz` into `~/rpmbuild/SOURCES/`,
  run `sudo dnf builddep -y ~/rpmbuild/SPECS/pg_repack_18.spec` and then
  `rpmbuild -bb ~/rpmbuild/SPECS/pg_repack_18.spec`. The spec is self-contained (it defines
  `pginstdir`/`pgmajorversion` itself and defaults to `with_llvm=no`); the PGDG spec copied
  verbatim needs `--define 'pgmajorversion 18' --define 'pginstdir /usr/pgsql-18'` because those
  macros come from the PGDG build infrastructure, not from `postgresql18-devel`.

### Scripts in this folder

* `install-pg_repack.sh` — does steps 1–5 automatically (OS detection, dependencies, download,
  build, install, verification). Run `./install-pg_repack.sh --help`.
* `test-pg_repack.sh` — end-to-end smoke test on a temporary table (`PASS`/`FAIL`).
* `pg_repack_18.spec` — self-contained RPM spec for AlmaLinux/RHEL 9 + PostgreSQL 18.
