// Broker route tests, at the dispatch layer: no sockets, no network. They
// exercise the same `AppState` the binary builds (sessions, static fallback,
// dev provider) with synthetic Requests.

use init::clone {Clone}
use http::types {Body, Headers, Method, Request, Response, Uri}
use moon::static_files {StaticConfig, Static.new_cache}
use oauth::state {OauthStateStore.new}
use oauth::http_client {OauthHttp}
use jsonwebtoken::verifier {JwtVerifier}
use lib::atproto_verify {atp_deps_new}
use forge_online::{
    Provider, Whoami, whoami_decode, whoami_csrf, whoami_identity, identity_subject,
    path_providers, path_me, path_logout, path_dev_session, path_client_metadata
}
use lib::config {Config}
use lib::session {forge_sessions_new}
use lib::dispatch {AppState, dispatch}

def test_config : Config :=
    { public_origin := "http://127.0.0.1:8099", port := 8099u16,
      static_dir := "target/web/forge-online-test-missing", secure := false,
      dev_enabled := true, csrf_secret := "test-secret",
      atproto_client_name := "Mo Venture", atproto_scope := "atproto",
      discord_client_id := Option.none, discord_client_secret := Option.none,
      steam_api_key := Option.none,
      steam_openid_url := "https://steamcommunity.com/openid/login",
      providers := [Provider.atproto, Provider.steam, Provider.dev] : Config }

def make_state : IO (Option AppState) := do {
    let sr <- forge_sessions_new test_config;
    match sr {
        Result.err _ => IO.pure Option.none,
        Result.ok sessions => do {
            let states <- OauthStateStore.new 600i64 8i64;
            let http <- OauthHttp.fake List.empty List.empty;
            let atp <- atp_deps_new http (JwtVerifier.fake true);
            let cache <- Static.new_cache;
            let st : AppState :=
                { cfg := test_config, sessions := sessions, states := states, atp := atp,
                  static_cfg := StaticConfig.default test_config.static_dir, cache := cache
                  : AppState };
            IO.pure (Option.some st)
        }
    }
}

def uri_of (path : String) : Uri :=
    Uri.uri "http" Option.none "127.0.0.1" Option.none path Option.none Option.none

def get (path : String) : Request := Request.get (uri_of path)

def post (path : String) : Request :=
    let r : Request := Request.get (uri_of path) in
    { r with method := Method.POST }

def body_text (r : Response) : String :=
    match r.body {
        Body.text s => s,
        Body.empty => "",
        Body.bytes _ => "",
        Body.stream _ => "",
        Body.form _ => ""
    }

def with_header (r : Request) (k : String) (v : String) : Request :=
    { r with headers := Headers.set k v r.headers }

def origin_header : String := "origin"

#[test]
def test_providers_route : IO Bool := do {
    let st_r <- make_state;
    match st_r {
        Option.none => IO.pure false,
        Option.some st => do {
            let res <- dispatch st (get path_providers);
            IO.pure (res.status == 200u16
                && String.contains (body_text res) "\"atproto\""
                && String.contains (body_text res) "\"dev\"")
        }
    }
}

#[test]
def test_me_requires_a_session : IO Bool := do {
    let st_r <- make_state;
    match st_r {
        Option.none => IO.pure false,
        Option.some st => do {
            let res <- dispatch st (get path_me);
            IO.pure (res.status == 401u16)
        }
    }
}

#[test]
def test_client_metadata_is_same_origin : IO Bool := do {
    let st_r <- make_state;
    match st_r {
        Option.none => IO.pure false,
        Option.some st => do {
            let res <- dispatch st (get path_client_metadata);
            IO.pure (res.status == 200u16
                && String.contains (body_text res) "http://127.0.0.1:8099/client-metadata.json"
                && String.contains (body_text res) "\"redirect_uris\":[\"http://127.0.0.1:8099/\"]")
        }
    }
}

#[test]
def test_method_not_allowed_on_me_post : IO Bool := do {
    let st_r <- make_state;
    match st_r {
        Option.none => IO.pure false,
        Option.some st => do {
            let res <- dispatch st (post path_me);
            IO.pure (res.status == 405u16)
        }
    }
}

#[test]
def test_static_fallback_is_404_without_a_build : IO Bool := do {
    let st_r <- make_state;
    match st_r {
        Option.none => IO.pure false,
        Option.some st => do {
            let res <- dispatch st (get "/no-such-asset.js");
            IO.pure (res.status == 404u16)
        }
    }
}

#[test]
def test_dev_sign_in_then_me_then_csrf_logout : IO Bool := do {
    let st_r <- make_state;
    match st_r {
        Option.none => IO.pure false,
        Option.some st0 => do {
            let st : AppState := st0;
            let login <- dispatch st (post path_dev_session);
            match Headers.get "set-cookie" login.headers {
                Option.none => IO.pure false,
                Option.some cookie => do {
                    let me_req : Request := with_header (get path_me) "cookie" (Clone.clone (Shared.of cookie));
                    let me <- dispatch st me_req;
                    match whoami_decode (body_text me) {
                        Result.err _ => IO.pure false,
                        Result.ok who0 => do {
                            let who : Whoami := who0;
                            let csrf : String := whoami_csrf who;
                            let subject_ok : Bool := identity_subject (whoami_identity who) == "dev:player";
                            let no_csrf <- dispatch st
                                (with_header (with_header (post path_logout) origin_header
                                    "http://127.0.0.1:8099") "cookie" (Clone.clone (Shared.of cookie)));
                            let with_csrf <- dispatch st
                                (with_header (with_header (with_header (post path_logout) origin_header
                                    "http://127.0.0.1:8099") "x-csrf-token" csrf) "cookie" (Clone.clone (Shared.of cookie)));
                            let after <- dispatch st
                                (with_header (get path_me) "cookie" (Clone.clone (Shared.of cookie)));
                            IO.pure (me.status == 200u16 && subject_ok
                                && no_csrf.status == 403u16
                                && with_csrf.status == 204u16
                                && after.status == 401u16)
                        }
                    }
                }
            }
        }
    }
}
