// forge-online: the wire contract between the browser and the auth broker.
//
// One sign-in is one provider identity. The broker issues a session whose
// `Whoami` is exactly this shape, and the page renders it. Nothing here holds
// tokens, cookies or atproto types: this mote is pure, builds natively and for
// wasm, and is unit-tested natively.
//
// `avatar` is encoded as a string with "" meaning "none" (this is our own
// wire, not atproto's absent-not-null rule), so the JSON stays flat.

use std::derive {derive_copy, derive_clone}
use json::json {Json, Json.parse, Json.to_string}
use init::copy {Copy}

// `Json` is an immutable tree; sharing it is a true copy (the same reason
// forge's `Level` has an identity instance). It lets the decoders read several
// members of one document without threading clones through every helper.
pub instance Copy Json {
    def copy (j : Json) : Pair Json Json := Pair.pair j j
}

/// Which provider proved the identity.
#[derive Copy Clone]
pub type Provider {
    atproto,
    discord,
    steam,
    dev
}

pub def provider_name (p : Provider) : String :=
    match p {
        Provider.atproto => "atproto",
        Provider.discord => "discord",
        Provider.steam => "steam",
        Provider.dev => "dev"
    }

pub def provider_label (p : Provider) : String :=
    match p {
        Provider.atproto => "AT Protocol",
        Provider.discord => "Discord",
        Provider.steam => "Steam",
        Provider.dev => "Dev"
    }

pub def provider_of (s : String) : Result String Provider :=
    if s == "atproto" then Result.ok Provider.atproto
    else if s == "discord" then Result.ok Provider.discord
    else if s == "steam" then Result.ok Provider.steam
    else if s == "dev" then Result.ok Provider.dev
    else Result.err (String.concat "unknown provider: " s)

/// One signed-in provider identity. `subject` is the provider's stable id: a
/// DID for atproto, a snowflake for Discord, a SteamID64 for Steam, and
/// `dev:<name>` for the development provider. `display` is already sanitized.
#[derive Copy Clone]
pub struct Identity {
    provider : Provider,
    subject : String,
    display : String,
    avatar : String
}

pub def identity_make (p : Provider) (subject : String) (display : String) (avatar : String) : Identity :=
    { provider := p, subject := subject, display := sanitize_display display,
      avatar := sanitize_avatar avatar : Identity }

pub def identity_provider (i : Identity) : Provider := i.provider

pub def identity_subject (i : Identity) : String := i.subject

pub def identity_display (i : Identity) : String := i.display

/// "" means no avatar.
pub def identity_avatar (i : Identity) : String := i.avatar

pub def identity_has_avatar (i : Identity) : Bool := Bool.not (String.is_empty i.avatar)

/// The longest display name the UI will render.
pub def display_max : I64 := 64

/// The longest avatar URL accepted.
pub def avatar_max : I64 := 512

/// Drop control bytes (below 0x20 and DEL), trim the ends, cap the length.
/// Provider display names are attacker-controlled text and end up in the DOM.
#[terminating]
def clean_bytes (bs : List U8) (acc : List U8) : List U8 :=
    match bs {
        List.empty => acc,
        List.cons b rest =>
            if b < 32 then clean_bytes rest acc
            else if b == 127 then clean_bytes rest acc
            else clean_bytes rest (List.cons b acc)
    }

#[terminating]
def reverse_bytes (bs : List U8) (acc : List U8) : List U8 :=
    match bs {
        List.empty => acc,
        List.cons b rest => reverse_bytes rest (List.cons b acc)
    }

def cap_text (s : String) : String :=
    if String.length s > display_max then String.slice s 0 display_max else s

pub def sanitize_display (s : String) : String :=
    let trimmed : String := String.trim s in
    let cleaned : String := String.from_list (reverse_bytes (clean_bytes (String.to_list trimmed) List.empty) List.empty) in
    cap_text cleaned

/// An avatar is either empty or a plain https URL; anything else is dropped.
pub def sanitize_avatar (s : String) : String :=
    let t : String := String.trim s in
    if String.is_empty t then ""
    else if Bool.not (String.starts_with "https://" t) then ""
    else if String.length t > avatar_max then ""
    else if String.contains t " " then ""
    else t

pub def identity_valid (i : Identity) : Bool :=
    let subj : String := i.subject in
    let disp : String := i.display in
    Bool.not (String.is_empty subj)
        && String.length subj <= 512
        && Bool.not (String.is_empty disp)
        && (Bool.not (identity_has_avatar i) || String.starts_with "https://" i.avatar)

// ── JSON ─────────────────────────────────────────────────────────────

def field (what : String) (key : String) (j : Json) : Result String Json :=
    match Json.get_object j {
        Result.err e => Result.err e,
        Result.ok o =>
            match Json.object_get key o {
                Option.none => Result.err (String.concat what (String.concat " is missing `" (String.concat key "`"))),
                Option.some v => Result.ok v
            }
    }

def opt_field_str (key : String) (j : Json) : Option String :=
    match Json.get_object j {
        Result.err _ => Option.none,
        Result.ok o =>
            match Json.object_get key o {
                Option.none => Option.none,
                Option.some v =>
                    match Json.get_str v {
                        Result.err _ => Option.none,
                        Result.ok s => Option.some s
                    }
            }
    }

def required_str (what : String) (key : String) (j : Json) : Result String String :=
    match field what key j {
        Result.err e => Result.err e,
        Result.ok v => Json.get_str v
    }

pub def identity_to_json (i : Identity) : Json :=
    Json.make_object_pairs
        [Pair.pair "provider" (Json.make_str (provider_name i.provider)),
         Pair.pair "subject" (Json.make_str i.subject),
         Pair.pair "display" (Json.make_str i.display),
         Pair.pair "avatar" (Json.make_str i.avatar)]

pub def identity_of_json (j : Json) : Result String Identity :=
    match required_str "identity" "provider" j {
        Result.err e => Result.err e,
        Result.ok ps =>
            match provider_of ps {
                Result.err e => Result.err e,
                Result.ok p =>
                    match required_str "identity" "subject" j {
                        Result.err e => Result.err e,
                        Result.ok subject =>
                            match required_str "identity" "display" j {
                                Result.err e => Result.err e,
                                Result.ok display =>
                                    let avatar : String :=
                                        match opt_field_str "avatar" j {
                                            Option.some a => a,
                                            Option.none => ""
                                        } in
                                    let i : Identity := identity_make p subject display avatar in
                                    if identity_valid i then Result.ok i
                                    else Result.err "identity is not valid (empty subject/display or a bad avatar)"
                            }
                    }
            }
    }

/// What `/api/me` and the sign-in responses return.
#[derive Copy Clone]
pub struct Whoami {
    identity : Identity,
    expires_at : I64,
    csrf_token : String
}

pub def whoami_make (i : Identity) (expires_at : I64) (csrf : String) : Whoami :=
    { identity := i, expires_at := expires_at, csrf_token := csrf : Whoami }

pub def whoami_identity (w : Whoami) : Identity := w.identity

pub def whoami_expires_at (w : Whoami) : I64 := w.expires_at

pub def whoami_csrf (w : Whoami) : String := w.csrf_token

pub def whoami_to_json (w : Whoami) : Json :=
    Json.make_object_pairs
        [Pair.pair "identity" (identity_to_json w.identity),
         Pair.pair "expires_at" (Json.make_num_int w.expires_at),
         Pair.pair "csrf_token" (Json.make_str w.csrf_token)]

pub def whoami_of_json (j : Json) : Result String Whoami :=
    match field "whoami" "identity" j {
        Result.err e => Result.err e,
        Result.ok ij =>
            match identity_of_json ij {
                Result.err e => Result.err e,
                Result.ok i =>
                    match field "whoami" "expires_at" j {
                        Result.err e => Result.err e,
                        Result.ok ev =>
                            match Json.get_num_i64 (Json.get_num ev) {
                                Result.err e => Result.err e,
                                Result.ok expires_at =>
                                    match required_str "whoami" "csrf_token" j {
                                        Result.err e => Result.err e,
                                        Result.ok csrf =>
                                            Result.ok (whoami_make i expires_at csrf)
                                    }
                            }
                    }
            }
    }

pub def whoami_encode (w : Whoami) : String := Json.to_string (whoami_to_json w)

pub def whoami_decode (s : String) : Result String Whoami :=
    match Json.parse s {
        Result.err e => Result.err (String.concat "whoami is not JSON: " (Json.ParseError.to_string e)),
        Result.ok j => whoami_of_json j
    }

/// What `/api/providers` advertises so the page and the broker agree on which
/// buttons exist and what the atproto client is called.
#[derive Copy Clone]
pub struct ProvidersInfo {
    providers : List Provider,
    atproto_scope : String,
    atproto_client_name : String
}

pub def providers_make (ps : List Provider) (scope : String) (name : String) : ProvidersInfo :=
    { providers := ps, atproto_scope := scope, atproto_client_name := name : ProvidersInfo }

pub def providers_list (p : ProvidersInfo) : List Provider := p.providers

pub def providers_scope (p : ProvidersInfo) : String := p.atproto_scope

pub def providers_client_name (p : ProvidersInfo) : String := p.atproto_client_name

#[terminating]
def providers_json (ps : List Provider) : List Json :=
    match ps {
        List.empty => List.empty,
        List.cons p rest => List.cons (Json.make_str (provider_name p)) (providers_json rest)
    }

#[terminating]
def reverse_providers (ps : List Provider) (acc : List Provider) : List Provider :=
    match ps {
        List.empty => acc,
        List.cons p rest => reverse_providers rest (List.cons p acc)
    }

#[terminating]
def providers_of_json_list (js : List Json) (acc : List Provider) : Result String (List Provider) :=
    match js {
        List.empty => Result.ok (reverse_providers acc List.empty),
        List.cons j rest =>
            match Json.get_str j {
                Result.err e => Result.err e,
                Result.ok s =>
                    match provider_of s {
                        Result.err e => Result.err e,
                        Result.ok p => providers_of_json_list rest (List.cons p acc)
                    }
            }
    }

pub def providers_info_to_json (p : ProvidersInfo) : Json :=
    Json.make_object_pairs
        [Pair.pair "providers" (Json.make_array (providers_json p.providers)),
         Pair.pair "atproto_scope" (Json.make_str p.atproto_scope),
         Pair.pair "atproto_client_name" (Json.make_str p.atproto_client_name)]

pub def providers_info_of_json (j : Json) : Result String ProvidersInfo :=
    match field "providers" "providers" j {
        Result.err e => Result.err e,
        Result.ok pv =>
            match Json.get_array pv {
                Result.err e => Result.err e,
                Result.ok js =>
                    match providers_of_json_list js List.empty {
                        Result.err e => Result.err e,
                        Result.ok ps =>
                            match required_str "providers" "atproto_scope" j {
                                Result.err e => Result.err e,
                                Result.ok scope =>
                                    match required_str "providers" "atproto_client_name" j {
                                        Result.err e => Result.err e,
                                        Result.ok name =>
                                            Result.ok (providers_make ps scope name)
                                    }
                            }
                    }
            }
    }

pub def providers_info_encode (p : ProvidersInfo) : String := Json.to_string (providers_info_to_json p)

pub def providers_info_decode (s : String) : Result String ProvidersInfo :=
    match Json.parse s {
        Result.err e => Result.err (String.concat "providers is not JSON: " (Json.ParseError.to_string e)),
        Result.ok j => providers_info_of_json j
    }
