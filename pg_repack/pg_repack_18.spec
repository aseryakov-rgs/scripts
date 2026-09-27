############################################################################
# pg_repack_18.spec — самостоятельный (self-contained) spec для AlmaLinux 9
#                     и PostgreSQL 18 из репозитория PGDG (https://yum.postgresql.org)
#
# Основан на официальном спеке PGDG (pgdg-packaging/pgdg-rpms, 1.5.3-7PGDG),
# но не зависит от макросов инфраструктуры PGDG (%{pginstdir}, %{pgmajorversion}
# определены здесь сами), поэтому собирается обычной командой:
#
#     rpmbuild -bb ~/rpmbuild/SPECS/pg_repack_18.spec
#
# Как собирать — см. README.md, раздел «AlmaLinux 9 + PostgreSQL 18».
#
# Важно про LLVM (JIT): в PGDG-сборке postgresql18-devel включён with_llvm=yes,
# поэтому "make" пытается скомпилировать bitcode через clang и вызвать llvm-lto.
# Если clang/llvm не установлены — сборка падает на "/usr/bin/clang-19: No such
# file or directory".  По умолчанию здесь llvm выключен (with_llvm=no).
# Если нужен JIT-биткод, собирайте так:
#     rpmbuild -bb --define 'llvm 1' ~/rpmbuild/SPECS/pg_repack_18.spec
############################################################################

# major-версия PostgreSQL (можно переопределить: --define 'pgmajorversion 17')
%{!?pgmajorversion:%global pgmajorversion 18}
%global sname pg_repack
%global pginstdir /usr/pgsql-%{pgmajorversion}

# 1 = собирать JIT-биткод (нужны clang и llvm), 0 = не собирать (clang не нужен)
%{!?llvm:%global llvm 0}

%if %llvm
%global with_llvm_arg %{nil}
%else
%global with_llvm_arg with_llvm=no
%endif

Name:           %{sname}_%{pgmajorversion}
Version:        1.5.3
Release:        1%{?dist}
Summary:        Reorganize tables in PostgreSQL databases with minimal locks
License:        BSD
URL:            https://github.com/reorg/pg_repack
Source0:        https://github.com/reorg/pg_repack/archive/refs/tags/ver_%{version}.tar.gz
# Файл должен лежать в ~/rpmbuild/SOURCES/ver_1.5.3.tar.gz (имя = basename URL).

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  postgresql%{pgmajorversion}-devel
BuildRequires:  readline-devel
BuildRequires:  zlib-devel
# библиотеки, которые PGDG-сборка PostgreSQL 18 добавляет в "pg_config --libs":
#   -lz -llz4 -lzstd -lssl -lcrypto -lcurl -lnuma
BuildRequires:  lz4-devel
BuildRequires:  libzstd-devel
BuildRequires:  openssl-devel
BuildRequires:  libcurl-devel
BuildRequires:  numactl-devel
%if %llvm
BuildRequires:  clang
BuildRequires:  llvm
%endif

Requires:       postgresql%{pgmajorversion}

%description
pg_repack is a PostgreSQL extension which lets you remove bloat from tables and
indexes, and optionally restore the physical order of clustered indexes.
Unlike CLUSTER and VACUUM FULL it works online, without holding an exclusive
lock on the processed tables during processing.

Пакет ставит серверную часть расширения (pg_repack.so + pg_repack.control +
pg_repack--1.5.3.sql) в /usr/pgsql-%{pgmajorversion} и клиент /usr/pgsql-%{pgmajorversion}/bin/pg_repack.
После установки пакета включите расширение в нужной базе:
    sudo -u postgres psql -d mydb -c "CREATE EXTENSION pg_repack;"

%if %llvm
%package llvmjit
Summary:        Just-in-time compilation support for %{sname}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description llvmjit
This package provides JIT support (LLVM bitcode) for %{sname}.
%endif

%prep
%setup -q -n %{sname}-ver_%{version}

%build
PATH=%{pginstdir}/bin:$PATH make %{?_smp_mflags} %{with_llvm_arg}

%install
rm -rf %{buildroot}
PATH=%{pginstdir}/bin:$PATH make %{with_llvm_arg} DESTDIR=%{buildroot} install

%files
%license COPYRIGHT
%doc README.rst doc/%{sname}.rst
%{pginstdir}/bin/%{sname}
%{pginstdir}/lib/%{sname}.so
%{pginstdir}/share/extension/%{sname}.control
%{pginstdir}/share/extension/%{sname}--*.sql

%if %llvm
%files llvmjit
%{pginstdir}/lib/bitcode/%{sname}*.bc
%{pginstdir}/lib/bitcode/%{sname}/*.bc
%{pginstdir}/lib/bitcode/%{sname}/pgut/*.bc
%endif

%changelog
* Mon Sep 28 2026 Your Name <you@example.com> - 1.5.3-1
- Initial local build for PostgreSQL 18 on AlmaLinux 9
- Based on the official PGDG spec (1.5.3-7PGDG), self-contained macros
- LLVM bitcode is off by default (build with --define 'llvm 1' to enable it)
