#!/usr/bin/env bash
# Vendor raylib's C sources at a pinned commit.
#
# raylib is used as a plain directory of C files, not as a Zig package. That is
# deliberate: the build runner imports the build.zig of every package named in
# build.zig.zon, and raylib's own build.zig chases Zig master a few weeks behind
# it. Pulling raylib in as a package therefore breaks whenever Zig moves and
# raylib has not caught up, which for a repo that tracks master is most weeks.
# The C sources have no such problem, so we compile them ourselves.
set -euo pipefail

REPO="https://github.com/raysan5/raylib.git"
# raylib 6.0.0-dev. Bump deliberately, then re-run `zig build test`.
COMMIT="9f3cadf1e618f125bd9b282c7759f8cb26ce17fc"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/vendor/raylib"

if [ -f "$dest/.commit" ] && [ "$(cat "$dest/.commit")" = "$COMMIT" ]; then
  echo "raylib already at $COMMIT"
  exit 0
fi

rm -rf "$dest"
mkdir -p "$dest"
git -C "$dest" init -q
git -C "$dest" remote add origin "$REPO"
git -C "$dest" fetch -q --depth 1 origin "$COMMIT"
git -C "$dest" checkout -q FETCH_HEAD
rm -rf "$dest/.git"

# Keep only what we compile. raylib's examples/ alone is 72 MB and none of it
# is built here.
find "$dest" -mindepth 1 -maxdepth 1 ! -name src ! -name LICENSE -exec rm -rf {} +
rm -rf "$dest/src/external/RGFW"

echo "$COMMIT" > "$dest/.commit"
echo "raylib vendored at $COMMIT"
