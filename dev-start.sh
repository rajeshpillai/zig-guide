#!/usr/bin/env bash
#
# Start the full development environment.
#
# The site cannot build until `zig build` has emitted the wasm + manifest, and
# editing a snippet has no effect until that step reruns. This script wires both
# halves together so the dev loop is just "save the file".
#
#   ./dev-start.sh                 # build snippets, then serve with hot reload
#   ./dev-start.sh --verify        # also run the full CI gate before serving
#   ./dev-start.sh --port 3000     # serve on a different port
#   ./dev-start.sh --host          # expose on the local network
#   ./dev-start.sh --no-watch      # don't rebuild snippets on change
#   ./dev-start.sh --clean         # discard generated artifacts first
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PORT=4321
VERIFY=0
WATCH=1
CLEAN=0
HOST_FLAG=()
POLL_SECONDS=1
MIN_NODE_MAJOR=22

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ args ----

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     PORT="${2:?--port needs a value}"; shift 2 ;;
    --port=*)   PORT="${1#*=}"; shift ;;
    --host)     HOST_FLAG=(--host); shift ;;
    --verify)   VERIFY=1; shift ;;
    --no-watch) WATCH=0; shift ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
done

# --------------------------------------------------------- prerequisites ----

step "Checking prerequisites"

command -v zig  >/dev/null || die "zig not found on PATH. Install Zig master: https://ziglang.org/download/"
command -v node >/dev/null || die "node not found on PATH. Node ${MIN_NODE_MAJOR}+ is required."
command -v npm  >/dev/null || die "npm not found on PATH."

ZIG_VERSION="$(zig version)"
NODE_VERSION="$(node --version)"
NODE_MAJOR="${NODE_VERSION#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"

(( NODE_MAJOR >= MIN_NODE_MAJOR )) \
  || die "Node ${MIN_NODE_MAJOR}+ required, found ${NODE_VERSION}."

info "zig  ${ZIG_VERSION}"
info "node ${NODE_VERSION}"

# This guide tracks master; a tagged release will very likely fail to build.
case "$ZIG_VERSION" in
  *-dev*) ;;
  *) warn "This guide targets Zig master; ${ZIG_VERSION} looks like a tagged release."
     warn "Snippets may fail to compile. See the 'Zig version' section of README.md." ;;
esac

# ----------------------------------------------------------------- clean ----

if (( CLEAN )); then
  step "Removing generated artifacts"
  # node_modules/.vite too: a stale dependency-optimization cache surfaces as
  # "504 (Outdated Optimize Dep)" in the browser rather than as a build error.
  rm -rf web/public/wasm web/dist web/.astro web/node_modules/.vite .zig-cache zig-out
  info "cleaned"
fi

# ------------------------------------------------------------ site deps ----

if [[ ! -d web/node_modules ]]; then
  step "Installing site dependencies (first run)"
  (cd web && npm install)
elif [[ web/package-lock.json -nt web/node_modules ]]; then
  step "Lockfile changed — syncing site dependencies"
  (cd web && npm install)
fi

# ------------------------------------------------------------- snippets ----

# Full CI gate: compiles, runs, and diffs stdout for every snippet.
if (( VERIFY )); then
  step "Verifying snippets against ${ZIG_VERSION}"
  zig build verify || die "snippet verification failed — fix the snippets above, or start without --verify"
  info "all snippets compile and run"
fi

step "Building snippet wasm + manifest"
zig build || die "zig build failed. Run 'zig build verify' to see per-snippet errors."
info "web/public/wasm/ is up to date"

# -------------------------------------------------------------- watcher ----

# Content checksum rather than mtimes: portable, and it ignores touches that
# didn't actually change anything (no inotifywait/fswatch on this box).
snapshot() {
  find snippets -type f \( -name '*.zig' -o -name '*.expected' \) -exec cksum {} + \
    | sort | cksum
}

watch_snippets() {
  # Plain `zig build` only compiles; `verify` also runs each snippet and diffs
  # stdout against its .expected file. Honour whichever the user asked for so
  # --verify keeps holding during the session, not just at startup.
  local -a rebuild
  if (( VERIFY )); then rebuild=(zig build verify); else rebuild=(zig build); fi

  local previous current
  previous="$(snapshot)"
  while sleep "$POLL_SECONDS"; do
    current="$(snapshot)"
    [[ "$current" == "$previous" ]] && continue
    previous="$current"

    printf '\n%s==>%s snippet change detected — %s\n' "$BOLD" "$RESET" "${rebuild[*]}"
    # Must stay inside an `if`: `set -e` would otherwise kill this background
    # watcher the first time a snippet fails to build. `pipefail` makes the
    # pipeline report zig's status rather than sed's.
    if "${rebuild[@]}" 2>&1 | sed 's/^/    /'; then
      printf '    %sok%s — reload the page to pick up the new wasm\n' "$GREEN" "$RESET"
    else
      printf '    %sbuild failed%s — the site is still serving the last good wasm\n' "$RED" "$RESET"
    fi
  done
}

WATCHER_PID=""
cleanup() {
  [[ -n "$WATCHER_PID" ]] && kill "$WATCHER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if (( WATCH )); then
  watch_snippets &
  WATCHER_PID=$!
  step "Watching snippets/ for changes (pid ${WATCHER_PID})"
else
  step "Snippet watching disabled"
  info "rerun 'zig build' by hand after editing a snippet"
fi

# ----------------------------------------------------------------- serve ----

cd web

# Astro keeps a lock file, and silently attaches to an existing server rather
# than honouring --port. Without this, a second run appears to start on the
# requested port but actually serves nothing there.
if npx astro dev status 2>&1 | grep -q "Dev server running"; then
  step "Stopping a dev server left over from a previous run"
  npx astro dev stop >/dev/null 2>&1 || true
  sleep 1
fi

step "Starting Astro dev server"
info "http://localhost:${PORT}"
printf '\n'

# Astro owns the foreground; the EXIT trap stops the watcher when it quits.
# (With no TTY — e.g. output redirected — Astro daemonizes itself instead.)
exec npx astro dev --port "$PORT" "${HOST_FLAG[@]}"
