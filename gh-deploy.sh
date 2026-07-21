#!/usr/bin/env bash
#
# Build, verify, and publish the site to GitHub Pages.
#
# Runs the same gates CI does before publishing anything, because the whole
# premise of this guide is that what ships has been executed:
#
#   1. zig build verify   — every snippet compiles and runs on current Zig
#   2. astro build        — the site builds
#   3. npm run e2e        — every playground runs in a real browser
#   4. push web/dist to the gh-pages branch
#
#   ./gh-deploy.sh                    # full run
#   ./gh-deploy.sh --skip-e2e         # skip the browser pass (faster)
#   ./gh-deploy.sh --dry-run          # build and verify, but do not push
#
# GitHub Pages must be set to deploy from the `gh-pages` branch. If you use
# the Actions-based deployment in .github/workflows/ci.yml instead, you do not
# need this script — pushing to main is enough.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BRANCH="gh-pages"
SKIP_E2E=0
DRY_RUN=0

# A project site is served from /<repo>/, so assets must be built with that
# prefix or every absolute URL 404s.
REPO_NAME="$(basename -s .git "$(git config --get remote.origin.url 2>/dev/null || echo zig-guide)")"
: "${SITE_URL:=https://$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#').github.io}"
: "${BASE_PATH:=/${REPO_NAME}/}"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-e2e) SKIP_E2E=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --branch)   BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    -h|--help)  sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
done

command -v zig >/dev/null || die "zig not found on PATH"
command -v git >/dev/null || die "git not found on PATH"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured"

# Publishing a tree that does not match the commit makes the deployed site
# impossible to trace back to a revision.
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty — commit or stash first (deploys must be traceable)"
fi

SOURCE_COMMIT="$(git rev-parse --short HEAD)"

step "Verifying snippets against $(zig version)"
zig build verify || die "snippet verification failed — not deploying"
info "all snippets compile and run"

step "Building snippet wasm + manifest"
rm -rf web/public/wasm
zig build || die "zig build failed"
info "$(find web/public/wasm -name '*.wasm' | wc -l) snippets built"

step "Installing site dependencies"
(cd web && npm ci --silent 2>/dev/null || npm install --silent)

step "Building site"
info "SITE_URL=$SITE_URL  BASE_PATH=$BASE_PATH"
(cd web && SITE_URL="$SITE_URL" BASE_PATH="$BASE_PATH" npx astro build) \
  || die "site build failed"

if (( SKIP_E2E )); then
  step "Skipping browser verification (--skip-e2e)"
else
  step "Verifying in a real browser"
  # BASE_PATH must reach the e2e too: a project site embeds that prefix in
  # every absolute URL, so a server mounted at root 404s on every page.
  (cd web && BASE_PATH="$BASE_PATH" npm run e2e) \
    || die "browser verification failed — not deploying"
fi

# Pages does not run Jekyll for us, and Jekyll would eat the _astro directory.
touch web/dist/.nojekyll

if (( DRY_RUN )); then
  step "Dry run — built and verified, nothing pushed"
  info "output is in web/dist"
  exit 0
fi

step "Publishing web/dist to origin/$BRANCH"
# `git subtree` would need dist committed on main. Instead build a single
# orphan commit from the output directory and force-push it: the branch is a
# published artifact, not history worth preserving.
WORKTREE="$(mktemp -d)"
cleanup() { rm -rf "$WORKTREE"; }
trap cleanup EXIT

git -C web/dist init -q
git -C web/dist checkout -q -b "$BRANCH"
git -C web/dist add -A
git -C web/dist -c user.name="$(git config user.name)" \
    -c user.email="$(git config user.email)" \
    commit -q -m "Deploy from ${SOURCE_COMMIT}"
git -C web/dist push -q --force "$(git remote get-url origin)" "$BRANCH"
rm -rf web/dist/.git

step "Done"
info "source commit: ${SOURCE_COMMIT}"
info "published to:  ${SITE_URL%/}${BASE_PATH}"
info "if this is the first deploy, set Pages to serve from the '$BRANCH' branch"
