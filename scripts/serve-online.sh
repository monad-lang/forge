#!/usr/bin/env bash
# Build an app, then serve the page and the auth API from one broker process.
#
#   devenv shell -- scripts/serve-online.sh mo-venture
#   PORT=9000 NO_BUILD=1 scripts/serve-online.sh mo-venture
#
# Development defaults: loopback origin, the dev provider enabled (it signs in
# a named player without a provider), no TLS. Production sets PUBLIC_ORIGIN,
# CSRF_SECRET, FORGE_ONLINE_DEV=0 and terminates TLS at a reverse proxy; Moon
# is plain HTTP.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-mo-venture}"
port="${PORT:-8080}"

if [ -z "${NO_BUILD:-}" ]; then
    "$root/scripts/web-build.sh" "$app"
fi

export FORGE_STATIC_DIR="${FORGE_STATIC_DIR:-$root/target/web/$app}"
export PUBLIC_ORIGIN="${PUBLIC_ORIGIN:-http://127.0.0.1:$port}"
export FORGE_PORT="$port"
export FORGE_ONLINE_DEV="${FORGE_ONLINE_DEV:-1}"

echo "serve-online: $PUBLIC_ORIGIN  (dev provider: $FORGE_ONLINE_DEV)"
exec monad run "$root/services/forge-online"
