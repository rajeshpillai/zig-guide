#!/usr/bin/env bash
#
# Update the local Zig toolchain and report what the new compiler breaks.
#
# You normally do not need this: CI re-verifies against fresh master nightly
# and republishes when green. Run it when you want to fix a break locally, or
# to move ahead of the schedule.
#
#   ./update-zig.sh                 # refresh master, then verify
#   ./update-zig.sh --check         # report the available version, change nothing
#   ./update-zig.sh --force          # reinstall even if already current
#   ./update-zig.sh --version 0.18.0
#
# asdf will not re-download a version it already has, so refreshing `master`
# means uninstalling it first. That is the one genuinely non-obvious step, and
# the reason this script exists.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="master"
CHECK_ONLY=0
FORCE=0
UP_TO_DATE=0

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   CHECK_ONLY=1; shift ;;
    --force)   FORCE=1; shift ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    -h|--help) sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

command -v asdf >/dev/null || die "asdf not found on PATH"
command -v zig  >/dev/null || die "zig not found on PATH"

CURRENT="$(zig version)"
step "Current: Zig ${CURRENT}"

# What is actually published right now?
AVAILABLE=""
if command -v curl >/dev/null && command -v python3 >/dev/null; then
  AVAILABLE="$(curl -fsS --max-time 20 https://ziglang.org/download/index.json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("master",{}).get("version",""))' \
    2>/dev/null || true)"
fi

if [[ -n "$AVAILABLE" ]]; then
  info "latest master upstream: ${AVAILABLE}"
  if [[ "$AVAILABLE" == "$CURRENT" && "$VERSION" == "master" ]]; then
    printf '    %salready on the latest master%s\n' "$GREEN" "$RESET"
    UP_TO_DATE=1
  fi
else
  warn "could not reach ziglang.org; proceeding without a version comparison"
fi

if (( CHECK_ONLY )); then
  exit 0
fi

if (( UP_TO_DATE && !FORCE )); then
  step "Skipping reinstall — already current (use --force to reinstall anyway)"
else
  step "Installing Zig ${VERSION}"
  if [[ "$VERSION" == "master" ]]; then
    # asdf treats `master` as an ordinary version name and skips the download
    # if the directory exists, so an in-place `asdf install` is a no-op.
    # Remove it first to actually pick up today's nightly.
    info "removing the existing master so asdf re-downloads it"
    asdf uninstall zig master || true
  fi
  asdf install zig "$VERSION"
fi

NEW="$(zig version)"
step "Now: Zig ${NEW}"
if [[ "$NEW" == "$CURRENT" ]]; then
  info "unchanged"
fi

# The build cache keys on compiler version, but a stale cache is the first
# thing to suspect if results look impossible.
rm -rf .zig-cache

step "Verifying every snippet against ${NEW}"
if zig build verify; then
  printf '\n%sAll snippets compile and run on Zig %s.%s\n' "$GREEN" "$NEW" "$RESET"
  info "publish with ./gh-deploy.sh, or just let the nightly CI do it"
  exit 0
fi

printf '\n%sSome snippets need updating for Zig %s.%s\n' "$RED" "$NEW" "$RESET"
cat <<'EOS'

    The output above names each file and line. For each one:

      1. Fix the snippet.
      2. Update the chapter prose to teach the NEW shape, and say what the old
         one was — that note is the most valuable part for a reader arriving
         from a stale tutorial.
      3. Re-run ./update-zig.sh (or `zig build verify`) until it is silent.

    Nothing is published while this fails, so the live site keeps serving the
    last verified version.
EOS
exit 1
