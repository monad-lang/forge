#!/usr/bin/env bash
# Build the forge web demo and serve it for a browser.
#
#   devenv shell -- scripts/web-serve.sh          # http://localhost:8080
#   PORT=9000 devenv shell -- scripts/web-serve.sh
#   NO_BUILD=1 scripts/web-serve.sh               # serve the last build
#
# Any static server works (the page is plain files under target/web); this
# uses Python's, bound to localhost. ES modules and WebAssembly do not load
# from file:// URLs, so opening index.html directly will not work.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
port="${PORT:-8080}"

if [ -z "${NO_BUILD:-}" ]; then
    "$root/scripts/web-build.sh"
fi
[ -f "$root/target/web/app.wasm" ] \
    || { echo "web-serve: no build in target/web (drop NO_BUILD)" >&2; exit 1; }
command -v python3 >/dev/null \
    || { echo "web-serve: python3 not found; serve target/web with any static server" >&2; exit 1; }

echo "web-serve: http://localhost:$port  (Ctrl-C to stop)"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$root/target/web"
