#!/usr/bin/env bash
# Build the forge web demo for the browser target and drive it over monad's
# recording stub DOM + stub WebGL in Node (CI has no browser).
#
#   devenv shell -- scripts/web-smoke.sh            # webgl2, webgl1, none
#   MONAD_SRC=/path/to/monad scripts/web-smoke.sh
#
# The build is scripts/web-build.sh. The stubs (`stub_dom.mjs`,
# `stub_gl.mjs`) are not shipped either, so they come from the same monad
# checkout (`MONAD_SRC`, default `../monad`) at the pinned rev.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
monad_src="${MONAD_SRC:-$root/../monad}"
out="$root/target/web"

"$root/scripts/web-build.sh"

rev="$(sed -n 's/^rev = "\([0-9a-f]*\)"$/\1/p' "$root/mote.toml" | head -n 1)"
mkdir -p "$out/smoke"
for f in stub_dom.mjs stub_gl.mjs; do
    git -C "$monad_src" show "${rev}:wasm/web/smoke/$f" > "$out/smoke/$f"
done
cp "$root/tests/web/forge_webgl_smoke.mjs" "$out/smoke/"

for mode in webgl2 webgl1 none; do
    node "$out/smoke/forge_webgl_smoke.mjs" "$out/app.wasm" "$mode"
done
