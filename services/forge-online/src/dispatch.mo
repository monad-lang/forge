// The broker's HTTP dispatch: API/auth routes first, the built page as a
// static fallback. Same origin, no CORS, no `Host`-derived configuration.
//
// Routes (M1): liveness, atproto client metadata, provider advertisement,
// who-am-I, logout and the loopback dev provider. The atproto session
// exchange is wired in `atproto_verify.mo` (M2); until then it fails closed.

use std::ref {Ref, Ref.get, Ref.set}
use json::json {Json, Json.to_string, Json.make_str, Json.make_num_int, Json.make_object_pairs}
use forge_online::{
    identity_subject, whoami_identity, minted_token, ticket_ttl_ms, path_ws_prefix,
    err_not_found
}
use init::clone {Clone}
use init::copy {Copy}
use http::types {Body, Headers, HttpVersion, Method, Request, Response, Uri}
use http::uri {Uri.parse_query}
use moon::router {Route, Router.get, Router.post, Router.route}
use moon::session {Session}
use moon::static_files {EtagCache, StaticConfig, Static.handler_with}
use oauth::state {OauthStateStore}
use atproto_oauth::client_metadata {
    Atp.ClientConfig, Atp.client_metadata, Atp.hosted_client_id, Atp.redirect_uri
}
use forge_online::{
    Provider, Identity, provider_name, identity_make, whoami_encode, providers_info_encode,
    ProvidersInfo, path_providers, path_me, path_logout, path_atproto_session,
    path_client_metadata, path_healthz, path_dev_session, path_dev_auth, path_ws_ticket,
    err_invalid_request, err_unauthorized, err_forbidden, err_invalid_csrf,
    err_not_found, err_provider_unavailable, err_invalid_token, error_json,
    TicketTable, tickets_new, ticket_mint, minted_table, minted_token, ticket_sweep,
    tickets_count
}
use lib::config {Config, config_providers_info}
use lib::atproto_verify {AtpDeps, verify_exchange}
use lib::tickets {TicketSource, ticket_source_new, ticket_source_table, ticket_issue}
use lib::relay {Relay, relay_new, relay_handler, now_ms}
use moon::handler_t {HandlerT, HttpError}
use moon::context {Ctx}
use http::websocket_io {WsConfig}

use moon::context {Ctx}
use http::websocket_io {WsConfig}
use lib::session {
    ForgeSessions, forge_sessions_load, forge_sessions_whoami, forge_sessions_sign_in,
    forge_sessions_touch, forge_sessions_sign_out, forge_sessions_csrf_ok,
    with_cookie_pairs, whoami_json_response
}

pub struct AppState {
    cfg : Config,
    sessions : ForgeSessions,
    states : OauthStateStore,
    atp : AtpDeps,
    static_cfg : StaticConfig,
    cache : EtagCache,
    /// The co-op relay: its room table and its live sockets.
    relay : Relay,
    /// The ticket table, shared with the relay (which consumes from it).
    tickets : TicketSource
}

// Config is immutable and the rest are shared handle values; an identity copy
// is a true copy (the same reason `Json`/`Level` have one).
pub instance Copy AppState {
    def copy (st : AppState) : Pair AppState AppState := Pair.pair st st
}

// Requests are read-only here; a shared copy is what lets one dispatch read
// the method, path, headers and query of the same request.
pub instance Copy Request {
    def copy (r : Request) : Pair Request Request := Pair.pair r r
}

// ── request helpers ──────────────────────────────────────────────────

def req_path (req : Request) : String :=
    match req.uri {
        Uri.uri _ _ _ _ path _ _ => path
    }

def req_query (req : Request) : List (Pair String String) :=
    match req.uri {
        Uri.uri _ _ _ _ _ q _ =>
            match q {
                Option.none => List.empty,
                Option.some s => Uri.parse_query s
            }
    }

#[terminating]
def query_lookup (name : String) (ps : List (Pair String String)) : Option String :=
    match ps {
        List.empty => Option.none,
        List.cons p rest =>
            match p {
                Pair.pair k v => if k == name then Option.some v else query_lookup name rest
            }
    }

def query_param (req : Request) (name : String) : Option String :=
    query_lookup name (req_query req)

def is_get_or_head (req : Request) : Bool :=
    match req.method {
        Method.GET => true,
        Method.HEAD => true,
        _ => false
    }

def is_api_or_auth (path : String) : Bool :=
    String.starts_with "/api/" path || String.starts_with "/auth/" path

def origin_ok (c : Config) (req : Request) : Bool :=
    match Headers.get "origin" req.headers {
        Option.none => c.dev_enabled,
        Option.some o => o == c.public_origin
    }

// ── response helpers ─────────────────────────────────────────────────

def common_headers (res : Response) : Response :=
    Response.with_header "Cache-Control" "no-store"
        (Response.with_header "Referrer-Policy" "no-referrer"
            (Response.with_header "X-Content-Type-Options" "nosniff"
                (Response.with_header "X-Frame-Options" "DENY" res)))

def error_response (status : U16) (code : String) (message : String) : Response :=
    common_headers (Response.json status (error_json code message))

def redirect_with_cookies (location : String) (cookies : List (Pair String String)) : Response :=
    with_cookie_pairs cookies (common_headers (Response.redirect 303u16 location))

/// The co-op half of `AppState`: one ticket table, shared with the relay that
/// spends from it. `Copy` (two handles), so building it once and reading both
/// fields is not an affine use.
pub struct Coop {
    tickets : TicketSource,
    relay : Relay
}

/// A named constructor: a `let x : T := { ... }` statement inside a `do` block
/// does not parse (G20).
pub def Coop.make (tickets : TicketSource) (relay : Relay) : IO Coop :=
    IO.pure { tickets := tickets, relay := relay : Coop }

pub instance Copy Coop {
    def copy (c : Coop) : Pair Coop Coop := Pair.pair c c
}

pub def coop_tickets (c : Coop) : TicketSource := c.tickets

pub def coop_relay (c : Coop) : Relay := c.relay

pub def coop_new : IO Coop := do {
    let tickets <- ticket_source_new;
    let table <- IO.pure (ticket_source_table tickets);
    let relay <- relay_new table;
    let out <- Coop.make tickets relay;
    IO.pure out
}

// ── handlers ─────────────────────────────────────────────────────────

def health (_req : Request) : IO Response :=
    IO.pure (common_headers (Response.ok_text "ok"))

def metadata (st : AppState) (_req : Request) : IO Response := do {
    let c : Config := st.cfg;
    let cinfo : Atp.ClientConfig :=
        { name := c.atproto_client_name, scope := c.atproto_scope,
          storage_prefix := "mo-venture" : Atp.ClientConfig };
    let body : String :=
        Atp.client_metadata cinfo (Atp.hosted_client_id c.public_origin)
            (Atp.redirect_uri c.public_origin);
    IO.pure (common_headers (Response.json 200u16 body))
}

def providers (st : AppState) (_req : Request) : IO Response := do {
    let info : ProvidersInfo := config_providers_info st.cfg;
    IO.pure (common_headers (Response.json 200u16 (providers_info_encode info)))
}

def me (st : AppState) (req : Request) : IO Response := do {
    let loaded <- forge_sessions_load st.sessions req;
    match loaded {
        Option.none => IO.pure (error_response 401u16 err_unauthorized "not signed in"),
        Option.some sess0 => do {
            let sess : Session := sess0;
            let w <- forge_sessions_whoami st.sessions sess;
            match w {
                Result.err e => IO.pure (error_response 500u16 err_invalid_request e),
                Result.ok who => do {
                    let cookies <- forge_sessions_touch st.sessions sess;
                    IO.pure (with_cookie_pairs cookies
                        (common_headers (whoami_json_response 200u16 who)))
                }
            }
        }
    }
}

def logout (st : AppState) (req : Request) : IO Response := do {
    if Bool.not (origin_ok st.cfg req)
    then IO.pure (error_response 403u16 err_forbidden "cross-origin request")
    else do {
        let loaded <- forge_sessions_load st.sessions req;
        match loaded {
            Option.none => IO.pure (error_response 401u16 err_unauthorized "not signed in"),
            Option.some sess0 =>
                let sess : Session := sess0 in
                if Bool.not (forge_sessions_csrf_ok st.sessions sess req)
                then IO.pure (error_response 403u16 err_invalid_csrf "bad CSRF token")
                else do {
                    let cookies <- forge_sessions_sign_out st.sessions req;
                    IO.pure (with_cookie_pairs cookies (common_headers Response.no_content))
                }
        }
    }
}

def dev_identity (name : String) : Identity :=
    let subject : String := String.concat "dev:" name in
    identity_make Provider.dev subject name ""

def dev_sign_in (st : AppState) (req : Request) (redirect : Bool) : IO Response := do {
    if Bool.not st.cfg.dev_enabled
    then IO.pure (error_response 404u16 err_not_found "not found")
    else do {
        let name : String :=
            match query_param req "name" {
                Option.some n =>
                    let n2 : String := Clone.clone (Shared.of n) in
                    if String.is_empty n2 then "player" else n,
                Option.none => "player"
            };
        let r <- forge_sessions_sign_in st.sessions (dev_identity name);
        match r {
            Result.err e => IO.pure (error_response 500u16 err_invalid_request e),
            Result.ok p =>
                match p {
                    Pair.pair who cookies =>
                        if redirect then IO.pure (redirect_with_cookies "/" cookies)
                        else IO.pure (with_cookie_pairs cookies
                            (common_headers (whoami_json_response 200u16 who)))
                }
        }
    }
}

def dev_auth (st : AppState) (req : Request) : IO Response :=
    dev_sign_in st req true

def dev_session (st : AppState) (req : Request) : IO Response :=
    dev_sign_in st req false

/// M2 replaces this with the DPoP proof + token verification pipeline.
def atproto_session (st : AppState) (req : Request) : IO Response := do {
    if Bool.not (origin_ok st.cfg req)
    then IO.pure (error_response 403u16 err_forbidden "cross-origin request")
    else do {
        let auth : Option String := Headers.get "authorization" req.headers;
        let dpop : Option String := Headers.get "dpop" req.headers;
        let url : String := String.concat st.cfg.public_origin path_atproto_session;
        let verified <- verify_exchange st.atp url auth dpop;
        match verified {
            Result.err e => IO.pure (error_response 401u16 err_invalid_token e),
            Result.ok v => do {
                let id : Identity := v.identity;
                let signed <- forge_sessions_sign_in st.sessions id;
                match signed {
                    Result.err e => IO.pure (error_response 500u16 err_invalid_request e),
                    Result.ok p =>
                        match p {
                            Pair.pair who cookies =>
                                IO.pure (with_cookie_pairs cookies
                                    (common_headers (whoami_json_response 200u16 who)))
                        }
                }
            }
        }
    }
}

/// `GET /api/ws-ticket`: mint a single-use upgrade ticket for the signed-in
/// player. Session-gated (no ticket without a session) and origin-checked like
/// the other mutations; it is a read, so it needs no CSRF token.
def ws_ticket (st : AppState) (req : Request) : IO Response := do {
    let loaded <- forge_sessions_load st.sessions req;
    match loaded {
        Option.none => IO.pure (error_response 401u16 err_unauthorized "not signed in"),
        Option.some sess0 =>
            let sess : Session := sess0 in
            if Bool.not (origin_ok st.cfg req)
            then IO.pure (error_response 403u16 err_forbidden "cross-origin request")
            else do {
                let w <- forge_sessions_whoami st.sessions sess;
                match w {
                    Result.err e => IO.pure (error_response 500u16 err_invalid_request e),
                    Result.ok who => do {
                        let now <- now_ms;
                        let subject : String := identity_subject (whoami_identity who);
                        let r <- ticket_issue st.tickets subject now;
                        match r {
                            Result.err e => IO.pure (error_response 503u16 err_provider_unavailable e),
                            Result.ok m => do {
                                let token <- IO.pure (minted_token m);
                                let body : String := ticket_json token now;
                                IO.pure (common_headers (Response.json 200u16 body))
                            }
                        }
                    }
                }
            }
    }
}

/// `{"ticket":"...","expires_ms":N,"path":"/api/ws/..."}`: the JSON the page
/// reads before it opens the socket. The path is spelled here so the client
/// never builds one.
def ticket_json (token : String) (now : I64) : String :=
    Json.to_string (Json.make_object_pairs
        [ Pair.pair "ticket" (Json.make_str token),
          Pair.pair "expires_ms" (Json.make_num_int (I64.add now ticket_ttl_ms)),
          Pair.pair "path" (Json.make_str (String.concat path_ws_prefix token)) ])

def static_response (st : AppState) (req : Request) : IO (Result String Response) := do {
    let r <- Static.handler_with st.static_cfg st.cache req;
    match r {
        Result.ok res => IO.pure (Result.ok (common_headers res)),
        Result.err _ => IO.pure (Result.err "not found")
    }
}

// ── dispatch ─────────────────────────────────────────────────────────

pub def dispatch (st : AppState) (req : Request) : IO Response := do {
    let routes : List Route :=
        [ Router.get path_healthz health,
          Router.get path_client_metadata (fn (r : Request) => metadata st r),
          Router.get path_providers (fn (r : Request) => providers st r),
          Router.get path_me (fn (r : Request) => me st r),
          Router.post path_logout (fn (r : Request) => logout st r),
          Router.post path_atproto_session (fn (r : Request) => atproto_session st r),
          Router.get path_dev_auth (fn (r : Request) => dev_auth st r),
          Router.get path_ws_ticket (fn (r : Request) => ws_ticket st r),
          Router.post path_dev_session (fn (r : Request) => dev_session st r) ];
    let res <- Router.route routes req;
    if res.status == 404u16 && is_get_or_head req
        && Bool.not (is_api_or_auth (req_path req))
    then do {
        let s <- static_response st req;
        match s {
            Result.ok out => IO.pure out,
            Result.err _ => IO.pure (error_response 404u16 err_not_found "not found")
        }
    }
    else IO.pure (common_headers res)
}

// ── the upgrade-aware server entry ──────────────────────────────────
//
// A WebSocket upgrade cannot come back from `Request -> IO Response`: the 101
// and the connection's takeover are two things, and moon's transformer path
// (`Server.run_t`) carries both. So the broker runs through this `HandlerT`:
// the co-op socket under `/api/ws/` is the relay's own handler, and every
// other path falls through to the ordinary dispatcher.
//
// Both halves share one `AppState`, so a ticket minted by `GET
// /api/ws-ticket` is spent by the relay from the same table.

/// Rebuild the `Request` a `Ctx` was made from. `Ctx` keeps the effective
/// path (a router scope may have rewritten it), the headers as a shared view
/// (cloned here, since a `Request` owns its own) and the body as bytes (the
/// only projection a borrowed view allows; none of this broker's routes
/// streams a request body).
def request_of_ctx (ctx : Ctx) : Request :=
    let hs : Headers := Clone.clone (Ctx.headers ctx) in
    let bytes : List U8 := Ctx.body_bytes ctx in
    let uri : Uri := Uri.uri "" Option.none "" Option.none (Ctx.path ctx) Option.none Option.none in
    { method := Ctx.method ctx, uri := uri, headers := hs, version := HttpVersion.http1_1,
      body := Body.bytes bytes, params := List.empty : Request }

/// The ordinary dispatcher as a `HandlerT` (nothing inside it upgrades).
def plain_handler (st : AppState) : HandlerT IO Response :=
    HandlerT.mk (fn (ctx : Ctx) => do {
        let res <- dispatch st (request_of_ctx ctx);
        IO.pure (Result.ok res)
    })

/// The broker's whole handler: the co-op socket under `/api/ws/`, then
/// everything else.
///
/// The prefix is checked here rather than with `RouterT.scope`, because a
/// scope rewrites the context's path to the stripped one and the relay reads
/// the ticket from the last segment of the FULL path.
pub def dispatch_t (st : AppState) : HandlerT IO Response :=
    dispatch_with st st.relay WsConfig.default

pub def dispatch_with (st : AppState) (relay : Relay) (ws_cfg : WsConfig) : HandlerT IO Response :=
    HandlerT.mk (fn (ctx : Ctx) => dispatch_at st relay ws_cfg ctx)

def dispatch_at (st : AppState) (relay : Relay) (ws_cfg : WsConfig) (ctx : Ctx)
    : IO (Result HttpError Response) :=
    if String.starts_with path_ws_prefix (Ctx.path ctx)
    then HandlerT.run (relay_handler relay ws_cfg) ctx
    else HandlerT.run (plain_handler st) ctx
