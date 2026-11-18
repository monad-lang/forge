#!/usr/bin/env bash
# Build the forge web demo for the browser target and drive it over monad's
# recording stub DOM + stub WebGL in Node (CI has no browser).
#
#   devenv shell -- scripts/web-smoke.sh            # both apps: webgl2, webgl1, none
#   devenv shell -- scripts/web-smoke.sh mo-venture # one app (or `demo`)
#   NO_BUILD=1 scripts/web-smoke.sh                 # rerun on the last builds
#   MONAD_SRC=/path/to/monad scripts/web-smoke.sh
#
# The build is scripts/web-build.sh. The stubs (`stub_dom.mjs`,
# `stub_gl.mjs`) are not shipped either, so they come from the same monad
# checkout (`MONAD_SRC`, default `../monad`) at the pinned rev.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
monad_src="${MONAD_SRC:-$root/../monad}"
rev="$(sed -n 's/^git_commit = "\([0-9a-f]*\)"$/\1/p' "$root/mote.lock" | head -n 1)"

# smoke APP SCRIPT: build APP, stage the stubs and SCRIPT, run all modes.
smoke() {
    local app="$1" script="$2" out="$root/target/web/$1"
    [ -n "${NO_BUILD:-}" ] || "$root/scripts/web-build.sh" "$app"
    mkdir -p "$out/smoke"
    for f in stub_dom.mjs stub_gl.mjs; do
        git -C "$monad_src" show "${rev}:wasm/web/smoke/$f" > "$out/smoke/$f"
    done
    cp "$root/tests/web/$script" "$out/smoke/"
    for mode in webgl2 webgl1 none; do
        node "$out/smoke/$script" "$out/app.wasm" "$mode"
    done
}

only="${1:-all}"
if [ "$only" = all ] || [ "$only" = demo ]; then smoke demo forge_webgl_smoke.mjs; fi
if [ "$only" = all ] || [ "$only" = mo-venture ]; then smoke mo-venture mo_venture_smoke.mjs; fi
