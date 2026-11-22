// The broker's HTTP dispatch: API/auth routes first, the built page as a
// static fallback. Same origin, no CORS, no `Host`-derived configuration.
//
// Routes (M1): liveness, atproto client metadata, provider advertisement,
// who-am-I, logout and the loopback dev provider. The atproto session
// exchange is wired in `atproto_verify.mo` (M2); until then it fails closed.

use init::clone {Clone}
use init::copy {Copy}
use http::types {Headers, Method, Request, Response, Uri}
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
    path_client_metadata, path_healthz, path_dev_session, path_dev_auth,
    err_invalid_request, err_unauthorized, err_forbidden, err_invalid_csrf,
    err_not_found, err_provider_unavailable, err_invalid_token, error_json
}
use lib::config {Config, config_providers_info}
use lib::atproto_verify {AtpDeps, verify_exchange}
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
    cache : EtagCache
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
