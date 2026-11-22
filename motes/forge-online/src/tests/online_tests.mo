// The wire contract's tests: provider names, display/avatar sanitization and
// JSON round-trips. If these drift, the page and the broker disagree.

use json::json {Json}
use lib::{
    Provider, provider_name, provider_label, provider_of,
    Identity, identity_make, identity_provider, identity_subject, identity_display,
    identity_has_avatar, identity_valid,
    display_max, sanitize_display, sanitize_avatar,
    identity_to_json, identity_of_json,
    Whoami, whoami_make, whoami_identity, whoami_expires_at, whoami_csrf, whoami_encode, whoami_decode,
    ProvidersInfo, providers_make, providers_list, providers_scope, providers_client_name,
    providers_info_encode, providers_info_decode,
    path_providers, path_me, path_logout, path_atproto_session, path_client_metadata,
    provider_start_path, provider_callback_path,
    err_unauthorized, error_json
}

def provider_is (a : Provider) (b : Provider) : Bool :=
    match a {
        Provider.atproto => match b { Provider.atproto => true, _ => false },
        Provider.discord => match b { Provider.discord => true, _ => false },
        Provider.steam => match b { Provider.steam => true, _ => false },
        Provider.dev => match b { Provider.dev => true, _ => false }
    }

def provider_of_is (s : String) (p : Provider) : Bool :=
    match provider_of s {
        Result.err _ => false,
        Result.ok q => provider_is q p
    }

#[test]
def test_provider_round_trip : Bool :=
    provider_of_is (provider_name Provider.atproto) Provider.atproto
        && provider_of_is (provider_name Provider.discord) Provider.discord
        && provider_of_is (provider_name Provider.steam) Provider.steam
        && provider_of_is (provider_name Provider.dev) Provider.dev

#[test]
def test_unknown_provider_is_an_error : Bool :=
    match provider_of "myspace" {
        Result.err e => String.contains e "unknown provider",
        Result.ok _ => false
    }

#[test]
def test_provider_labels : Bool :=
    provider_label Provider.atproto == "AT Protocol"
        && provider_label Provider.discord == "Discord"
        && provider_label Provider.steam == "Steam"

#[test]
def test_sanitize_strips_control_bytes : Bool :=
    sanitize_display (String.from_list [7, 97, 108, 105, 99, 101, 7]) == "alice"

#[test]
def test_sanitize_caps_length : Bool :=
    let long : String := String.repeat "a" 100 in
    String.length (sanitize_display long) == display_max

#[test]
def test_sanitize_cap_keeps_whole_characters : Bool :=
    let a : String := String.repeat "a" 63 in
    let e : String := String.from_list [195, 169] in
    let s : String := sanitize_display (String.concat a e) in
    Bool.not (String.is_empty s) && String.length s <= display_max

#[test]
def test_avatar_rejects_control_characters : Bool :=
    let tab : String := String.from_list [9] in
    let url : String := String.concat_list ["https://x/a", tab, "b"] in
    sanitize_avatar url == ""

#[test]
def test_avatar_must_be_https : Bool :=
    sanitize_avatar "https://cdn.example/a.png" == "https://cdn.example/a.png"
        && sanitize_avatar "http://cdn.example/a.png" == ""
        && sanitize_avatar "javascript:alert(1)" == ""
        && sanitize_avatar "https://cdn.example/a b.png" == ""

#[test]
def test_identity_round_trip : Bool :=
    let i : Identity := identity_make Provider.atproto "did:plc:abc" "alice.bsky.social" "" in
    match identity_of_json (identity_to_json i) {
        Result.err _ => false,
        Result.ok j0 =>
            let j : Identity := j0 in
            provider_is (identity_provider j) Provider.atproto
                && identity_subject j == "did:plc:abc"
                && identity_display j == "alice.bsky.social"
                && Bool.not (identity_has_avatar j)
    }

#[test]
def test_identity_requires_a_subject : Bool :=
    let i : Identity := identity_make Provider.dev "" "someone" "" in
    Bool.not (identity_valid i)

#[test]
def test_identity_decode_rejects_unknown_provider : Bool :=
    let text : String := "{\"provider\":\"myspace\",\"subject\":\"x\",\"display\":\"x\",\"avatar\":\"\"}" in
    match Json.parse text {
        Result.err _ => false,
        Result.ok j =>
            match identity_of_json j {
                Result.err _ => true,
                Result.ok _ => false
            }
    }

#[test]
def test_whoami_round_trip : Bool :=
    let i : Identity := identity_make Provider.discord "123456789" "alice" "https://cdn.example/a.png" in
    let w : Whoami := whoami_make i 1893456000000 "csrf-token" in
    match whoami_decode (whoami_encode w) {
        Result.err _ => false,
        Result.ok d0 =>
            let d : Whoami := d0 in
            whoami_expires_at d == 1893456000000
                && whoami_csrf d == "csrf-token"
                && identity_subject (whoami_identity d) == "123456789"
                && identity_has_avatar (whoami_identity d)
    }

#[test]
def test_providers_info_round_trip_keeps_order : Bool :=
    let p : ProvidersInfo := providers_make [Provider.atproto, Provider.discord, Provider.steam]
        "atproto" "Mo Venture" in
    match providers_info_decode (providers_info_encode p) {
        Result.err _ => false,
        Result.ok d0 =>
            let d : ProvidersInfo := d0 in
            providers_scope d == "atproto"
                && providers_client_name d == "Mo Venture"
                && match providers_list d {
                    List.cons a rest =>
                        match rest {
                            List.cons b more =>
                                provider_is a Provider.atproto && provider_is b Provider.discord
                                    && match more {
                                        List.cons c tail => provider_is c Provider.steam && List.length tail == 0,
                                        List.empty => false
                                    },
                            List.empty => false
                        },
                    List.empty => false
                }
    }

#[test]
def test_api_paths : Bool :=
    path_providers == "/api/providers"
        && path_me == "/api/me"
        && path_logout == "/api/logout"
        && path_atproto_session == "/api/atproto/session"
        && path_client_metadata == "/client-metadata.json"
        && provider_start_path Provider.discord == "/auth/discord/start"
        && provider_callback_path Provider.steam == "/auth/steam/callback"

#[test]
def test_error_json_shape : Bool :=
    let body : String := error_json err_unauthorized "no session" in
    String.contains body "\"error\":\"unauthorized\""
        && String.contains body "\"message\":\"no session\""
