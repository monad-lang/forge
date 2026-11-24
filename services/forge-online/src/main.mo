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
use moon::server {ServerConfig, Server.run_t}
use moon::static_files {StaticConfig, Static.new_cache}
use oauth::state {OauthStateStore, OauthStateStore.new}
use oauth::http_client {OauthHttp}
use jsonwebtoken::verifier {JwtVerifier}
use lib::atproto_verify {AtpDeps, atp_deps_new}
use lib::config {Config, load}
use lib::session {forge_sessions_new}
use lib::tickets {TicketSource}
use lib::relay {Relay}
use lib::dispatch {AppState, dispatch_t, coop_new, coop_tickets, coop_relay}

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
            let coop <- coop_new;
            let tickets <- IO.pure (coop_tickets coop);
            let relay <- IO.pure (coop_relay coop);
            let st : AppState :=
                { cfg := cfg, sessions := sessions, states := states, atp := atp,
                  static_cfg := StaticConfig.default cfg.static_dir, cache := cache,
                  relay := relay, tickets := tickets : AppState };
            let _ <- IO.println (String.concat "forge-online: " cfg.public_origin);
            // The transformer server, because a WebSocket upgrade needs the
            // connection's takeover slot and a `Request -> IO Response` route
            // cannot carry one. `dispatch_t` is the same routes plus the co-op
            // relay under `/api/ws/`.
            // Bind the base config first: a record update on a call result
            // does not parse (PLAN.md G11's sibling).
            let scfg0 : ServerConfig := ServerConfig.on cfg.port;
            let scfg : ServerConfig := { scfg0 with max_in_flight := 64i64 };
            let r <- Server.run_t scfg (dispatch_t st);
            let out <- serve_result r;
            return out
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

/// Report what `Server.run_t` answered. A named helper because a `match` as
/// the last statement of a `do` block does not parse.
def serve_result (r : Result String Unit) : IO Unit :=
    match r {
        Result.err e => fail e,
        Result.ok _ => IO.pure unit
    }
