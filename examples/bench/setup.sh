#!/usr/bin/env bash
# Installs every system the benchmarks compare against, under one cache
# root, and writes <root>/env.sh naming each binary. Each step is skipped
# when its result is already there, so a second run does nothing. Nothing
# needs root: on Linux the toolchain and libraries come from a conda-forge
# environment inside the root, and on macOS from Homebrew.
#
#   examples/bench/setup.sh            # install whatever is missing
#   PROBALOG_BENCH_HOME=... setup.sh   # somewhere other than ~/.cache
#
# The root must not contain spaces: CUDD builds with libtool, which
# splits paths at them.
set -euo pipefail

ROOT="${PROBALOG_BENCH_HOME:-$HOME/.cache/probalog-bench}"
case "$ROOT" in
  *\ *) echo "PROBALOG_BENCH_HOME must not contain spaces: $ROOT" >&2; exit 1 ;;
esac
mkdir -p "$ROOT"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { echo "setup.sh: $*" >&2; exit 1; }
# Runs a noisy build step, showing its output only if it fails.
quiet() {
  local log="$ROOT/build.log"
  "$@" >"$log" 2>&1 || { tail -40 "$log" >&2; exit 1; }
}
os="$(uname -s)"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# --- toolchain and libraries -------------------------------------------------

CENV="$ROOT/conda"
if [ "$os" = Linux ]; then
  # probalog's rsdd library is only built for x86_64.
  [ "$(uname -m)" = x86_64 ] || die "needs x86_64, found $(uname -m)"
  MAMBA="$ROOT/bin/micromamba"
  export MAMBA_ROOT_PREFIX="$ROOT/mamba"
  if [ ! -x "$MAMBA" ]; then
    say "downloading micromamba"
    mkdir -p "$ROOT/bin"
    curl -fsSL -o "$MAMBA" \
      https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-64
    chmod +x "$MAMBA"
  fi
  # gcc 13 rather than the newest: Souffle 2.5 and PSouffle predate it.
  # binutils for a plain `ar`, which the gcc packages only ship prefixed.
  # The package list is recorded, so adding to it updates an existing
  # environment rather than being skipped.
  packages="python=3.12 swi-prolog cmake make bison flex pkg-config jq unzip
            gcc=13 gxx=13 gcc_linux-64=13 gxx_linux-64=13 binutils
            readline ncurses libffi zlib sqlite ca-certificates"
  if [ "$(cat "$CENV/.complete" 2>/dev/null)" != "$(echo $packages)" ]; then
    if [ -d "$CENV/conda-meta" ]; then
      say "updating the conda environment"
      quiet "$MAMBA" install -y -p "$CENV" -c conda-forge --override-channels $packages
    else
      say "creating the conda environment"
      rm -rf "$CENV"
      quiet "$MAMBA" create -y -p "$CENV" -c conda-forge --override-channels $packages
    fi
    echo $packages > "$CENV/.complete"
  fi
  # No LD_LIBRARY_PATH: builds record the library path with -rpath, and
  # setting it would make the machine's own tools load conda's libraries.
  export PATH="$CENV/bin:$PATH"
  export CC=gcc CXX=g++
  export CPATH="$CENV/include" LIBRARY_PATH="$CENV/lib"
  # The environment's OpenSSL, which SWI-Prolog uses to fetch cplint, has
  # no certificate authorities of its own.
  export SSL_CERT_FILE="$CENV/ssl/cacert.pem"
  export CMAKE_PREFIX_PATH="$CENV" PKG_CONFIG_PATH="$CENV/lib/pkgconfig"
  export LDFLAGS="-L$CENV/lib -Wl,-rpath,$CENV/lib"
else
  command -v souffle >/dev/null || { say "installing Souffle"; brew install souffle; }
  command -v swipl >/dev/null || { say "installing SWI-Prolog"; brew install swi-prolog; }
fi

# --- Souffle (Linux) -----------------------------------------------------------

# Not on conda-forge, so built from its release source.
SF="$ROOT/souffle"
if [ "$os" = Linux ]; then
  if [ ! -x "$SF/bin/souffle" ]; then
    say "building Souffle 2.5 (several minutes)"
    rm -rf "$SF" "$ROOT/souffle-src"
    mkdir -p "$ROOT/souffle-src"
    curl -fsSL https://github.com/souffle-lang/souffle/archive/refs/tags/2.5.tar.gz \
      | tar xz -C "$ROOT/souffle-src" --strip-components=1
    quiet cmake -S "$ROOT/souffle-src" -B "$ROOT/souffle-src/build" -DCMAKE_BUILD_TYPE=Release \
                -DSOUFFLE_ENABLE_TESTING=OFF -DSOUFFLE_GIT=OFF -DCMAKE_INSTALL_PREFIX="$SF"
    quiet cmake --build "$ROOT/souffle-src/build" -j"$jobs"
    quiet cmake --install "$ROOT/souffle-src/build"
  fi
  SOUFFLE_BIN="$SF/bin/souffle"
else
  SOUFFLE_BIN="$(command -v souffle)"
fi

# --- ProbLog -------------------------------------------------------------

VENV="$ROOT/problog-venv"
if ! "$VENV/bin/problog" --version >/dev/null 2>&1 \
   || ! "$VENV/bin/python" -c "import pysdd" >/dev/null 2>&1; then
  say "installing ProbLog and pysdd"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  quiet "$VENV/bin/pip" install --upgrade pip problog pysdd
fi

# --- cplint ----------------------------------------------------------------

# Installed into the root rather than the user's pack directory, and keyed
# on the Prolog version, since its foreign library is built against it.
SWIPL_BIN="$(command -v swipl)"
swipl_version="$("$SWIPL_BIN" --version | awk '{print $3}')"
PACKS="$ROOT/swipl-packs-$swipl_version"
has_pita() {
  "$SWIPL_BIN" -g "attach_packs('$PACKS', []), use_module(library(pita))" -t halt >/dev/null 2>&1
}
if ! has_pita; then
  say "installing cplint for SWI-Prolog $swipl_version"
  rm -rf "$PACKS"
  mkdir -p "$PACKS"
  quiet "$SWIPL_BIN" -g "pack_install(cplint, [interactive(false), package_directory('$PACKS')])" -t halt
  has_pita || die "cplint installed but library(pita) does not load"
fi

# --- CUDD and PSouffle -----------------------------------------------------

PS="$ROOT/psouffle"
CUDD="$PS/cudd-install"
case "$os" in
  Darwin) CUDD_LIB="$CUDD/lib/libcudd.dylib" ;;
  *)      CUDD_LIB="$CUDD/lib/libcudd.so" ;;
esac
PS_SRC="$PS/src/souffle-full-artifact-ae"
PS_BIN="$PS_SRC/build/src/souffle"

if [ ! -f "$CUDD_LIB" ]; then
  say "building CUDD 3.0.0"
  mkdir -p "$PS"
  curl -fsSL https://github.com/ivmai/cudd/archive/refs/tags/cudd-3.0.0.tar.gz -o "$PS/cudd.tgz"
  tar xzf "$PS/cudd.tgz" -C "$PS"
  quiet sh -c "cd '$PS/cudd-cudd-3.0.0' && ./configure --prefix='$CUDD' --enable-shared --enable-obj \
               && make -j$jobs && make install"
fi

if [ ! -x "$PS_BIN" ]; then
  say "building PSouffle (a few minutes)"
  [ -d /opt/homebrew/opt/bison/bin ] && PATH="/opt/homebrew/opt/bison/bin:$PATH"
  mkdir -p "$PS/src"
  curl -fsSL https://zenodo.org/records/20091940/files/psouffle.zip -o "$PS/psouffle.zip"
  unzip -oq "$PS/psouffle.zip" -d "$PS/src"
  quiet cmake -S "$PS_SRC" -B "$PS_SRC/build" -DCMAKE_BUILD_TYPE=Release \
              -DSOUFFLE_ENABLE_TESTING=OFF \
              -DCUDD_INCLUDE_DIR="$CUDD/include" -DCUDD_LIBRARY="$CUDD_LIB"
  quiet cmake --build "$PS_SRC/build" -j"$jobs"
fi

# --- environment -------------------------------------------------------------

# BENCH_* are prepended to the search paths of the systems that need the
# conda environment at run time: PSouffle compiles and links each program.
if [ "$os" = Linux ]; then
  bench_path="$CENV/bin" bench_lib="$CENV/lib" bench_include="$CENV/include"
else
  bench_path="" bench_lib="" bench_include=""
fi
cat > "$ROOT/env.sh" <<EOF
export PROBLOG="$VENV/bin/problog"
export SWIPL="$SWIPL_BIN"
export CPLINT_PACKS="$PACKS"
export SOUFFLE="$SOUFFLE_BIN"
export PSOUFFLE="$PS_BIN"
export CUDD_LIB_DIR="$CUDD/lib"
export BENCH_PATH="$bench_path"
export BENCH_LIB="$bench_lib"
export BENCH_INCLUDE="$bench_include"
EOF
say "ready: $ROOT/env.sh"
