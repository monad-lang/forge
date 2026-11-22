// Forge Online: the auth broker.
//
// One process serves the built page and the API from the same origin. It is
// plain HTTP: production terminates TLS at a reverse proxy, and
// `PUBLIC_ORIGIN` is configuration, never derived from `Host`.
//
//   PUBLIC_ORIGIN=https://mo.example \
//   CSRF_SECRET=... \
//   FORGE_STATIC_DIR=/srv/mo-venture \
//   monad run services/forge-online
//
// Development:
//   scripts/serve-online.sh mo-venture
//   open http://127.0.0.1:8080

use std::io {IO.println}
use moon::server {Server.serve_concurrent}
use moon::static_files {StaticConfig, Static.new_cache}
use oauth::state {OauthStateStore, OauthStateStore.new}
use oauth::http_client {OauthHttp}
use jsonwebtoken::verifier {JwtVerifier}
use lib::atproto_verify {AtpDeps, atp_deps_new}
use lib::config {Config, load}
use lib::session {forge_sessions_new}
use lib::dispatch {AppState, dispatch}

def fail (message : String) : IO Unit := do {
    let _ <- IO.println (String.concat "forge-online: " message);
    return unit
}

def serve (cfg : Config) : IO Unit := do {
    let sessions_r <- forge_sessions_new cfg;
    match sessions_r {
        Result.err e => fail (String.concat "session store: " e),
        Result.ok sessions => do {
            let states <- OauthStateStore.new 600i64 8i64;
            let atp <- atp_deps_new OauthHttp.real JwtVerifier.real;
            let cache <- Static.new_cache;
            let st : AppState :=
                { cfg := cfg, sessions := sessions, states := states, atp := atp,
                  static_cfg := StaticConfig.default cfg.static_dir, cache := cache : AppState };
            let _ <- IO.println (String.concat "forge-online: " cfg.public_origin);
            let _ <- Server.serve_concurrent (dispatch st) cfg.port 64i64;
            return unit
        }
    }
}

def main : IO Unit := do {
    let cfg_r <- load;
    match cfg_r {
        Result.err e => fail e,
        Result.ok cfg => serve cfg
    }
}
