#!/usr/bin/env bash
# Installs every system the benchmarks compare against, under one cache
# root, and writes <root>/env.sh naming each binary. Each step is skipped
# when its result is already there, so a second run does nothing, and CI
# caches the whole root.
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
# Runs a noisy build step, showing its output only if it fails.
quiet() {
  local log="$ROOT/build.log"
  "$@" >"$log" 2>&1 || { tail -40 "$log" >&2; exit 1; }
}
os="$(uname -s)"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
die() { echo "setup.sh: $*" >&2; exit 1; }
# -n, so a missing sudo rule fails at once instead of waiting for a password
sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo -n"

# Linux packages are installed through apt with its archive directory
# inside the root, so a cached root needs no downloads.
DEBS="$ROOT/debs"
apt_install() {
  mkdir -p "$DEBS/partial"
  $sudo apt-get install -y -q -o Dir::Cache::Archives="$DEBS" "$@" >/dev/null
  $sudo chown -R "$(id -u):$(id -g)" "$DEBS"
}

# --- Linux prerequisites ---------------------------------------------------

# probalog's rsdd library is only built for x86_64, and the packages below
# come from Ubuntu's repositories and an Ubuntu-only PPA.
if [ "$os" = Linux ]; then
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || die "needs Ubuntu, found ${PRETTY_NAME:-unknown}"
  [ "$(uname -m)" = x86_64 ] || die "needs x86_64, found $(uname -m)"
  prereqs="software-properties-common lsb-release jq curl unzip python3 python3-venv
           python3-dev build-essential cmake bison flex libffi-dev zlib1g-dev
           libncurses-dev libreadline-dev mcpp"
  missing="$(for p in $prereqs; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done)"
  if [ -n "$missing" ]; then
    [ -z "$sudo" ] || $sudo true 2>/dev/null \
      || die "needs root or passwordless sudo to install: $(echo $missing)"
    say "installing prerequisites: $(echo $missing)"
    $sudo apt-get update -q >/dev/null
    apt_install $missing
  fi
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

# --- Souffle and SWI-Prolog ----------------------------------------------

if [ "$os" = Darwin ]; then
  command -v souffle >/dev/null || { say "installing Souffle"; brew install souffle; }
  command -v swipl >/dev/null || { say "installing SWI-Prolog"; brew install swi-prolog; }
else
  if [ ! -f "$ROOT/apt-sources-ready" ] || ! command -v swipl >/dev/null || ! command -v souffle >/dev/null; then
    say "adding the SWI-Prolog PPA"
    $sudo apt-add-repository -y ppa:swi-prolog/stable >/dev/null
    $sudo apt-get update -q >/dev/null
    touch "$ROOT/apt-sources-ready"
  fi
  if ! command -v swipl >/dev/null; then
    say "installing SWI-Prolog"
    apt_install swi-prolog-nox
  fi
  # Souffle is not packaged by Ubuntu; its releases carry .debs named for
  # the Ubuntu version they were built against.
  if ! command -v souffle >/dev/null; then
    deb="$(ls "$DEBS"/souffle_*.deb 2>/dev/null | head -1 || true)"
    if [ -z "$deb" ]; then
      say "downloading Souffle"
      rel="$(curl -fsSL https://api.github.com/repos/souffle-lang/souffle/releases/latest)"
      want="$(lsb_release -rs | tr -d .)"
      url="$(printf '%s' "$rel" | jq -r --arg v "$want" \
             '.assets[] | select(.name | test("ubuntu-" + $v + ".*\\.deb$")) | .browser_download_url')"
      [ -n "$url" ] || url="$(printf '%s' "$rel" | jq -r \
             '[.assets[] | select(.name | test("ubuntu.*\\.deb$")) | .browser_download_url] | sort | last')"
      mkdir -p "$DEBS"
      deb="$DEBS/souffle_$(basename "$url")"
      curl -fsSL -o "$deb" "$url"
    fi
    say "installing Souffle"
    apt_install "$deb"
  fi
fi

# --- cplint ----------------------------------------------------------------

# Installed into the root rather than the user's pack directory, and keyed
# on the Prolog version, since its foreign library is built against it.
swipl_version="$(swipl --version | awk '{print $3}')"
PACKS="$ROOT/swipl-packs-$swipl_version"
has_pita() {
  swipl -g "attach_packs('$PACKS', []), use_module(library(pita))" -t halt >/dev/null 2>&1
}
if ! has_pita; then
  say "installing cplint for SWI-Prolog $swipl_version"
  rm -rf "$PACKS"
  mkdir -p "$PACKS"
  swipl -g "pack_install(cplint, [interactive(false), package_directory('$PACKS')])" -t halt
  has_pita || { echo "cplint installed but library(pita) does not load" >&2; exit 1; }
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

cat > "$ROOT/env.sh" <<EOF
export PROBLOG="$VENV/bin/problog"
export SWIPL="$(command -v swipl)"
export CPLINT_PACKS="$PACKS"
export SOUFFLE="$(command -v souffle)"
export PSOUFFLE="$PS_BIN"
export CUDD_LIB_DIR="$CUDD/lib"
EOF
say "ready: $ROOT/env.sh"
