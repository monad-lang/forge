// The broker's configuration, from the environment.
//
// Same-origin is the whole design: `PUBLIC_ORIGIN` is the page's origin, the
// broker serves both the static page and the API there, and cookies are
// first-party. Never derive it from `Host`.
//
//   PUBLIC_ORIGIN       e.g. https://mo.example (default http://127.0.0.1:PORT)
//   FORGE_PORT          default 8080
//   FORGE_STATIC_DIR    default target/web/mo-venture
//   FORGE_ONLINE_DEV    1 enables the dev provider, loopback origins only
//   CSRF_SECRET         required when the origin is https
//   ATPROTO_SCOPE       default atproto
//   ATPROTO_CLIENT_NAME default Mo Venture
//   DISCORD_CLIENT_ID / DISCORD_CLIENT_SECRET   both or Discord is off
//   STEAM_API_KEY       optional (display names/avatars)
//   STEAM_OPENID_URL    default https://steamcommunity.com/openid/login

use std::io {IO.get_env}
use init::clone {Clone}
use init::copy {Copy}
use moon::csrf {Csrf.development_secret}
use forge_online::identity {Provider, providers_make, ProvidersInfo}

pub struct Config {
    public_origin : String,
    port : U16,
    static_dir : String,
    secure : Bool,
    dev_enabled : Bool,
    csrf_secret : String,
    atproto_client_name : String,
    atproto_scope : String,
    discord_client_id : Option String,
    discord_client_secret : Option String,
    steam_api_key : Option String,
    steam_openid_url : String,
    providers : List Provider
}

// Immutable configuration; sharing is a true copy and lets handlers read
// several members without threading clones.
pub instance Copy Config {
    def copy (c : Config) : Pair Config Config := Pair.pair c c
}

// ── small env helpers ────────────────────────────────────────────────

def env_or (name : String) (fallback : String) : IO String := do {
    let v <- IO.get_env name;
    match v {
        Option.none => IO.pure fallback,
        Option.some s =>
            let s2 : String := Clone.clone (Shared.of s) in
            if String.is_empty s2 then IO.pure fallback else IO.pure s
    }
}

def env_is (name : String) (want : String) : IO Bool := do {
    let v <- IO.get_env name;
    match v {
        Option.none => IO.pure false,
        Option.some s => IO.pure (s == want)
    }
}

def env_nonempty (name : String) : IO (Option String) := do {
    let v <- IO.get_env name;
    match v {
        Option.none => IO.pure Option.none,
        Option.some s =>
            let s2 : String := Clone.clone (Shared.of s) in
            if String.is_empty s2 then IO.pure Option.none else IO.pure (Option.some s)
    }
}

#[terminating]
def digit_u16 (i : I64) (ds : List U16) : U16 :=
    match ds {
        List.empty => 0u16,
        List.cons d rest => if I64.beq i 0 then d else digit_u16 (I64.sub i 1) rest
    }

#[terminating]
def parse_port_go (bytes : List U8) (acc : U16) (wide : I64) : Option U16 :=
    match bytes {
        List.empty => if I64.lt 0 wide then Option.some acc else Option.none,
        List.cons b rest =>
            let d : I64 := U8.to_i64 b - 48 in
            if d < 0 || I64.gt d 9
            then Option.none
            else
                let next_wide : I64 := wide * 10 + d in
                if I64.gt next_wide 65535
                then Option.none
                else parse_port_go rest
                    (U16.add (U16.mul acc 10u16)
                        (digit_u16 d [0u16, 1u16, 2u16, 3u16, 4u16, 5u16, 6u16, 7u16, 8u16, 9u16]))
                    next_wide
    }

pub def parse_port (s : String) : Option U16 :=
    if String.is_empty s then Option.none else parse_port_go (String.to_list s) 0u16 0

pub def strip_trailing_slash (s : String) : String :=
    if String.ends_with "/" s && String.length s > 1
    then String.slice s 0 (String.length s - 1)
    else s

pub def is_loopback_origin (s : String) : Bool :=
    String.starts_with "http://127.0.0.1" s
        || String.starts_with "http://localhost" s
        || String.starts_with "http://[::1]" s

def origin_shape_ok (s : String) : Bool :=
    let scheme : Bool :=
        String.starts_with "https://" s || String.starts_with "http://" s in
    scheme
        && Bool.not (String.contains s "?")
        && Bool.not (String.contains s "#")
        && Bool.not (String.contains s " ")

/// A `List Provider` in the order the overlay shows its buttons.
def provider_list (dev : Bool) (discord : Bool) : List Provider :=
    let ps0 : List Provider := [Provider.atproto] in
    let ps1 : List Provider := if discord then List.append ps0 [Provider.discord] else ps0 in
    let ps2 : List Provider := List.append ps1 [Provider.steam] in
    if dev then List.append ps2 [Provider.dev] else ps2

pub def load : IO (Result String Config) := do {
    let port_s <- env_or "FORGE_PORT" "8080";
    let port : U16 := match parse_port port_s {
        Option.some p => p,
        Option.none => 8080u16
    };
    let origin0 <- env_or "PUBLIC_ORIGIN" (String.concat "http://127.0.0.1:" port_s);
    let origin : String := strip_trailing_slash (String.trim origin0);
    let secure : Bool := String.starts_with "https://" origin;
    let dev_flag <- env_is "FORGE_ONLINE_DEV" "1";
    let dev_enabled : Bool := dev_flag && is_loopback_origin origin;
    let csrf_env <- env_nonempty "CSRF_SECRET";
    let csrf_secret : Option String :=
        match csrf_env {
            Option.some s => Option.some s,
            Option.none => if secure then Option.none else Option.some Csrf.development_secret
        };
    match csrf_secret {
        Option.none => IO.pure (Result.err "CSRF_SECRET must be set for an https origin"),
        Option.some secret =>
            if Bool.not (origin_shape_ok origin)
            then IO.pure (Result.err (String.concat "PUBLIC_ORIGIN is not a bare origin: " origin))
            else do {
                let static_dir <- env_or "FORGE_STATIC_DIR" "target/web/mo-venture";
                let client_name <- env_or "ATPROTO_CLIENT_NAME" "Mo Venture";
                let scope <- env_or "ATPROTO_SCOPE" "atproto";
                let discord_id <- env_nonempty "DISCORD_CLIENT_ID";
                let discord_secret <- env_nonempty "DISCORD_CLIENT_SECRET";
                let discord_id2 : Option String := Clone.clone (Shared.of discord_id);
                let discord_secret2 : Option String := Clone.clone (Shared.of discord_secret);
                let discord_on : Bool :=
                    match discord_id2 {
                        Option.none => false,
                        Option.some _ =>
                            match discord_secret2 {
                                Option.none => false,
                                Option.some _ => true
                            }
                    };
                let steam_key <- env_nonempty "STEAM_API_KEY";
                let steam_url <- env_or "STEAM_OPENID_URL" "https://steamcommunity.com/openid/login";
                let cfg : Config :=
                    { public_origin := origin, port := port, static_dir := static_dir,
                      secure := secure, dev_enabled := dev_enabled, csrf_secret := secret,
                      atproto_client_name := client_name, atproto_scope := scope,
                      discord_client_id := discord_id, discord_client_secret := discord_secret,
                      steam_api_key := steam_key, steam_openid_url := steam_url,
                      providers := provider_list dev_enabled discord_on : Config };
                IO.pure (Result.ok cfg)
            }
    }
}

pub def config_providers_info (c : Config) : ProvidersInfo :=
    providers_make c.providers c.atproto_scope c.atproto_client_name

pub def config_discord_enabled (c : Config) : Bool :=
    match c.discord_client_id {
        Option.none => false,
        Option.some _ =>
            match c.discord_client_secret {
                Option.none => false,
                Option.some _ => true
            }
    }
