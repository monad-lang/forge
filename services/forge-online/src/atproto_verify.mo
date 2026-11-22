// Verify an AT Protocol OAuth access token presented by the browser.
//
// The browser ran the flow with atproto-monad and holds a DPoP-bound access
// token (a JWT whose `cnf.jkt` is the thumbprint of its non-extractable
// P-256 key). It cannot hand the broker the private key, so the broker
// verifies both halves of the proof of possession:
//
//   1. the `DPoP` header is a proof signed by the public JWK it embeds, for
//      this exact request (`htm`/`htu`), fresh (`iat`), single-use (`jti`),
//      and bound to the token (`ath`);
//   2. the access token is a JWT signed by the authorization server, its
//      `sub` is a DID, and `cnf.jkt` is that same key's thumbprint.
//
// Trusting the token's `iss` would let anyone mint a token for anyone else's
// DID, so the last step walks DID -> PDS -> authorization server -> JWKS and
// verifies the token's signature with that server's key.
//
// Outbound fetches use `OauthHttp` (moose, zero redirects); the caller injects
// it, so the whole pipeline is testable with scripted responses.

use std::derive {derive_copy, derive_clone}
use init::clone {Clone}
use std::io {IO.epoch_time_nano}
use std::ref {Ref, Ref.get, Ref.set}
use json::json {Json}
use http::types {Body, Headers, Headers.empty, Response, Uri}
use http::uri {Uri.parse}
use oauth::http_client {OauthHttp, OauthHttp.send_get}
use oauth::errors {OauthError, OauthError.to_string}
use jsonwebtoken::jwt {Jwt, Jwt.parse, Jwt.verify}
use jsonwebtoken::verifier {JwtVerifier}
use atproto_identity::identity {
    Atp.did_document_url, Atp.did_document, Atp.DidDocument, Atp.is_handle, Atp.well_known_did
}
use atproto_oauth::oauth {
    Atp.resource_metadata, Atp.as_metadata, Atp.AsMetadata, Atp.origin_of
}
use atproto_oauth::dpop {Atp.htu, Atp.dpop_ath}
use atproto_oauth::client_metadata {Atp.jwk_xy, Atp.jwk_thumbprint, Atp.jwk_is_public}
use forge_online::identity {Identity, identity_make, Provider}

// The JSON tree is immutable; sharing it is a true copy, and the decoders
// read several members of one JWKS/metadata document.
pub instance Copy Json {
    def copy (j : Json) : Pair Json Json := Pair.pair j j
}

// JWTs are immutable claim maps; the checks read the header and the claims
// repeatedly.
pub instance Copy Jwt {
    def copy (j : Jwt) : Pair Jwt Jwt := Pair.pair j j
}

pub instance Copy Response {
    def copy (r : Response) : Pair Response Response := Pair.pair r r
}

// A DID document is immutable; its two members are both read here.
pub instance Copy Atp.DidDocument {
    def copy (d : Atp.DidDocument) : Pair Atp.DidDocument Atp.DidDocument := Pair.pair d d
}

pub struct AtpDeps {
    http : OauthHttp,
    verifier : JwtVerifier,
    /// `jkt:jti` -> expiry (epoch seconds), the replay window.
    replay : Ref (List (Pair String I64)),
    skew : I64
}

pub instance Copy AtpDeps {
    def copy (d : AtpDeps) : Pair AtpDeps AtpDeps := Pair.pair d d
}

pub def atp_deps_new (http : OauthHttp) (verifier : JwtVerifier) : IO AtpDeps := do {
    let replay <- Ref.new List.empty;
    IO.pure { http := http, verifier := verifier, replay := replay, skew := 60i64 : AtpDeps }
}

#[derive Copy Clone]
pub struct VerifiedAtp {
    identity : Identity,
    did : String,
    issuer : String,
    pds : String
}

// ── small helpers ────────────────────────────────────────────────────

def now_s : IO I64 := do {
    let n <- IO.epoch_time_nano;
    IO.pure (I64.div n 1000000000i64)
}

def abs_i64 (x : I64) : I64 := if x < 0 then 0 - x else x

def is_https (u : String) : Bool := String.starts_with "https://" u

def body_text (r : Response) : String :=
    match r.body {
        Body.text s => s,
        Body.empty => "",
        Body.bytes bs => String.from_list bs,
        Body.stream _ => "",
        Body.form _ => ""
    }

def claim (j : Jwt) (k : String) : Option Json :=
    Json.object_get k j.claims

def claim_str (j : Jwt) (k : String) : Option String :=
    match claim j k {
        Option.none => Option.none,
        Option.some v => match Json.get_str v { Result.ok s => Option.some s, Result.err _ => Option.none }
    }

def claim_i64 (j : Jwt) (k : String) : Option I64 :=
    match claim j k {
        Option.none => Option.none,
        Option.some v =>
            match Json.get_num_i64 (Json.get_num v) {
                Result.ok n => Option.some n,
                Result.err _ => Option.none
            }
    }

def header_str (j : Jwt) (k : String) : Option String :=
    match Json.object_get k j.header {
        Option.none => Option.none,
        Option.some v => match Json.get_str v { Result.ok s => Option.some s, Result.err _ => Option.none }
    }

def nested_str (j : Jwt) (outer : String) (inner : String) : Option String :=
    match claim j outer {
        Option.none => Option.none,
        Option.some o =>
            match Json.get_object o {
                Result.err _ => Option.none,
                Result.ok m =>
                    match Json.object_get inner m {
                        Option.none => Option.none,
                        Option.some v => match Json.get_str v { Result.ok s => Option.some s, Result.err _ => Option.none }
                    }
            }
    }

def require_opt (what : String) (v : Option String) : Result String String :=
    match v {
        Option.none => Result.err what,
        Option.some s0 =>
            let s : String := s0 in
            if String.is_empty s then Result.err what else Result.ok s
    }

def fetch_text (d : AtpDeps) (url : String) : IO (Result String String) := do {
    if Bool.not (is_https url)
    then IO.pure (Result.err "an upstream URL is not https")
    else match Uri.parse url {
        Result.err e => IO.pure (Result.err (String.concat "bad URL: " e)),
        Result.ok u => do {
            let r <- OauthHttp.send_get d.http u Headers.empty;
            match r {
                Result.err e => IO.pure (Result.err (OauthError.to_string e)),
                Result.ok resp0 =>
                    let resp : Response := resp0 in
                    if resp.status == 200u16
                    then IO.pure (Result.ok (body_text resp))
                    else IO.pure (Result.err "upstream request failed")
            }
        }
    }
}

/// One pass over the replay window: was `key` seen while live, and what
/// entries are still live. (One pass because a second use of the list would
/// be affine.)
#[terminating]
def replay_scan (key : String) (now : I64) (xs : List (Pair String I64))
    (dup : Bool) (kept : List (Pair String I64)) : Pair Bool (List (Pair String I64)) :=
    match xs {
        List.empty => Pair.pair dup (List.reverse kept),
        List.cons p rest =>
            match p {
                Pair.pair k0 exp0 =>
                    let k : String := k0 in
                    let exp : I64 := exp0 in
                    let live : Bool := exp > now in
                    let same : Bool := k == key && live in
                    let kept2 : List (Pair String I64) :=
                        if live then List.cons (Pair.pair k exp) kept else kept in
                    replay_scan key now rest (dup || same) kept2
            }
    }

#[terminating]
def handle_of (aliases : List String) : Option String :=
    match aliases {
        List.empty => Option.none,
        List.cons a rest =>
            if String.starts_with "at://" a
            then
                let h : String := String.drop 5 a in
                if String.is_empty h then handle_of rest else Option.some h
            else handle_of rest
    }

/// The display name: a handle only if the handle's own well-known document
/// points back at this DID (AT Protocol's reverse check). A DID document's
/// `alsoKnownAs` is self-asserted, so using it unchecked lets any DID display
/// as someone else's handle.
def verified_display (d : AtpDeps) (doc : Atp.DidDocument) (did : String) : IO String := do {
    match handle_of doc.also_known_as {
        Option.none => IO.pure did,
        Option.some handle0 =>
            let handle : String := handle0 in
            if Bool.not (Atp.is_handle handle)
            then IO.pure did
            else do {
                let url : String := String.concat_list ["https://", handle, "/.well-known/atproto-did"];
                let r <- fetch_text d url;
                match r {
                    Result.err _ => IO.pure did,
                    Result.ok body =>
                        match Atp.well_known_did body {
                            Result.err _ => IO.pure did,
                            Result.ok claimed =>
                                if claimed == did then IO.pure handle else IO.pure did
                        }
                }
            }
    }
}

// ── the pipeline ─────────────────────────────────────────────────────

/// `authorization` is the request's `Authorization` header and `dpop` its
/// `DPoP` header; `request_url` is this broker endpoint's absolute URL.
pub def verify_exchange (d : AtpDeps) (request_url : String)
    (authorization : Option String) (dpop : Option String)
    : IO (Result String VerifiedAtp) := do {
    match authorization {
        Option.none => IO.pure (Result.err "missing Authorization"),
        Option.some auth0 =>
            let auth : String := auth0 in
            if Bool.not (String.starts_with "DPoP " auth)
            then IO.pure (Result.err "Authorization is not a DPoP token")
            else
                let token : String := String.drop 5 auth in
                match dpop {
                    Option.none => IO.pure (Result.err "missing DPoP proof"),
                    Option.some proof_text => do {
                        match Jwt.parse proof_text {
                            Result.err _ => IO.pure (Result.err "the DPoP proof is not a JWT"),
                            Result.ok proof0 =>
                                let proof : Jwt := proof0 in
                                match require_opt "the DPoP proof has no typ" (header_str proof "typ") {
                                    Result.err e => IO.pure (Result.err e),
                                    Result.ok typ =>
                                        if Bool.not (typ == "dpop+jwt")
                                        then IO.pure (Result.err "the DPoP proof has the wrong typ")
                                        else
                                            match require_opt "the DPoP proof has no alg" (header_str proof "alg") {
                                                Result.err e => IO.pure (Result.err e),
                                                Result.ok alg =>
                                                    if Bool.not (alg == "ES256")
                                                    then IO.pure (Result.err "the DPoP proof is not ES256")
                                                    else verify_proof d request_url token proof
                                            }
                                }
                        }
                    }
                }
    }
}

def verify_proof (d : AtpDeps) (request_url : String) (token : String) (proof : Jwt)
    : IO (Result String VerifiedAtp) := do {
    match Json.object_get "jwk" proof.header {
        Option.none => IO.pure (Result.err "the DPoP proof has no jwk"),
        Option.some jwk =>
            let jwk_text : String := Json.to_string jwk in
            if Bool.not (Atp.jwk_is_public jwk_text)
            then IO.pure (Result.err "the DPoP jwk carries private material")
            else
                match Atp.jwk_xy jwk_text {
                    Result.err _ => IO.pure (Result.err "the DPoP jwk is not P-256"),
                    Result.ok xy =>
                        match xy {
                            Pair.pair x y =>
                                let jkt : String := Atp.jwk_thumbprint x y in
                                check_proof_claims d request_url token proof jwk_text jkt
                        }
                }
    }
}

def check_proof_claims (d : AtpDeps) (request_url : String) (token : String)
    (proof : Jwt) (jwk_text : String) (jkt : String) : IO (Result String VerifiedAtp) := do {
    let now <- now_s;
    match require_opt "the proof has no htm" (claim_str proof "htm") {
        Result.err e => IO.pure (Result.err e),
        Result.ok htm =>
            if Bool.not (htm == "POST")
            then IO.pure (Result.err "the proof htm is not POST")
            else
                match require_opt "the proof has no htu" (claim_str proof "htu") {
                    Result.err e => IO.pure (Result.err e),
                    Result.ok htu =>
                        if Bool.not (htu == Atp.htu request_url)
                        then IO.pure (Result.err "the proof htu is not this endpoint")
                        else
                            match claim_i64 proof "iat" {
                                Option.none => IO.pure (Result.err "the proof has no iat"),
                                Option.some iat =>
                                    if I64.gt (abs_i64 (I64.sub iat now)) d.skew
                                    then IO.pure (Result.err "the proof iat is outside the window")
                                    else
                                        match require_opt "the proof has no jti" (claim_str proof "jti") {
                                            Result.err e => IO.pure (Result.err e),
                                            Result.ok jti =>
                                                match require_opt "the proof has no ath" (claim_str proof "ath") {
                                                    Result.err e => IO.pure (Result.err e),
                                                    Result.ok ath =>
                                                        if Bool.not (ath == Atp.dpop_ath token)
                                                        then IO.pure (Result.err "the proof ath does not match the token")
                                                        else do {
                                                            let key : String := String.concat jkt (String.concat ":" jti);
                                                            let seen <- Ref.get d.replay;
                                                            match replay_scan key now seen false List.empty {
                                                                Pair.pair dup kept =>
                                                                    if dup
                                                                    then IO.pure (Result.err "the proof has been replayed")
                                                                    else do {
                                                                let jwks : Json :=
                                                                    Json.make_object_pairs
                                                                        [Pair.pair "keys"
                                                                            (Json.make_array
                                                                                [match Json.parse jwk_text { Result.ok j => j, Result.err _ => Json.make_null }])];
                                                                let verified <- Jwt.verify d.verifier jwks proof;
                                                                match verified {
                                                                    Result.err _ => IO.pure (Result.err "the proof signature is not valid"),
                                                                    Result.ok _ => do {
                                                                        let _ <- Ref.set d.replay
                                                                            (List.cons (Pair.pair key (I64.add now (I64.mul d.skew 2i64))) kept);
                                                                        check_token d token jkt
                                                                    }
                                                                }
                                                                    }
                                                            }
                                                        }
                                                }
                                        }
                            }
                }
    }
}

/// The pure part of the access-token checks: issuer is a secure origin, the
/// subject is a DID, the token is live, scoped, and bound to `jkt`.
def token_claims (t : Jwt) (now : I64) (skew : I64) (jkt : String)
    : Result String (Pair String String) :=
    match require_opt "the token has no iss" (claim_str t "iss") {
        Result.err e => Result.err e,
        Result.ok iss0 =>
            let iss : String := iss0 in
            if Bool.not (is_https iss) || Bool.not (iss == Atp.origin_of iss)
            then Result.err "the token issuer is not a secure origin"
            else
                match require_opt "the token has no sub" (claim_str t "sub") {
                    Result.err e => Result.err e,
                    Result.ok sub0 =>
                        let sub : String := sub0 in
                        if Bool.not (String.starts_with "did:" sub)
                        then Result.err "the token subject is not a DID"
                        else
                            match claim_i64 t "exp" {
                                Option.none => Result.err "the token has no exp",
                                Option.some exp =>
                                    if I64.lt exp (I64.sub now skew)
                                    then Result.err "the token has expired"
                                    else
                                        match claim_str t "scope" {
                                            Option.none => Result.err "the token has no scope",
                                            Option.some scope =>
                                                if Bool.not (String.contains scope "atproto")
                                                then Result.err "the token is not an atproto token"
                                                else
                                                    match nested_str t "cnf" "jkt" {
                                                        Option.none => Result.err "the token is not DPoP-bound",
                                                        Option.some bound0 =>
                                                            let bound : String := bound0 in
                                                            if Bool.not (bound == jkt)
                                                            then Result.err "the token is bound to another key"
                                                            else Result.ok (Pair.pair iss sub)
                                                    }
                                        }
                            }
                }
    }

def check_token (d : AtpDeps) (token : String) (jkt : String) : IO (Result String VerifiedAtp) := do {
    match Jwt.parse token {
        Result.err _ => IO.pure (Result.err "the access token is not a JWT"),
        Result.ok t0 =>
            let t : Jwt := t0 in
            do {
            let now <- now_s;
            match token_claims t now d.skew jkt {
                Result.err e => IO.pure (Result.err e),
                Result.ok issub =>
                    match issub {
                        Pair.pair iss0 sub0 =>
                            let iss : String := iss0 in
                            let sub : String := sub0 in
                            do {
                            let chain <- check_did_chain d sub iss token;
                            match chain {
                                Result.err e => IO.pure (Result.err e),
                                Result.ok doc0 =>
                                    let doc : Atp.DidDocument := doc0 in
                                    do {
                                    let pds : String :=
                                        match doc.pds {
                                            Option.some p => p,
                                            Option.none => ""
                                        };
                                    let display <- verified_display d doc sub;
                                    let identity : Identity :=
                                        identity_make Provider.atproto sub display "";
                                    IO.pure (Result.ok
                                        { identity := identity, did := sub, issuer := iss, pds := pds
                                          : VerifiedAtp })
                                }
                            }
                        }
                    }
            }
        }
    }
}

/// DID -> its PDS -> the authorization server's metadata -> its JWKS, then
/// verify the token's signature with that JWKS. Returns the DID document.
def check_did_chain (d : AtpDeps) (did : String) (iss : String) (token : String)
    : IO (Result String Atp.DidDocument) := do {
    let did_url : String := Atp.did_document_url did;
    let doc_r <- fetch_text d did_url;
    match doc_r {
        Result.err e => IO.pure (Result.err (String.concat "DID document: " e)),
        Result.ok doc_body =>
            match Atp.did_document did doc_body {
                Result.err e => IO.pure (Result.err (String.concat "DID document: " e)),
                Result.ok doc0 =>
                    let doc : Atp.DidDocument := doc0 in
                    match doc.pds {
                        Option.none => IO.pure (Result.err "the DID document names no PDS"),
                        Option.some pds0 =>
                            let pds : String := pds0 in
                            if Bool.not (is_https pds)
                            then IO.pure (Result.err "the PDS endpoint is not secure")
                            else do {
                                let prm_url : String := String.concat pds "/.well-known/oauth-protected-resource";
                                let prm_r <- fetch_text d prm_url;
                                match prm_r {
                                    Result.err e => IO.pure (Result.err (String.concat "protected-resource metadata: " e)),
                                    Result.ok prm_body =>
                                        match Atp.resource_metadata prm_body {
                                            Result.err e => IO.pure (Result.err e),
                                            Result.ok as_issuer0 =>
                                                let as_issuer : String := as_issuer0 in
                                                if Bool.not (as_issuer == iss)
                                                then IO.pure (Result.err "the PDS names a different authorization server")
                                                else do {
                                                    let as_url : String := String.concat iss "/.well-known/oauth-authorization-server";
                                                    let as_r <- fetch_text d as_url;
                                                    match as_r {
                                                        Result.err e => IO.pure (Result.err (String.concat "AS metadata: " e)),
                                                        Result.ok as_body0 =>
                                                            let as_body : String := as_body0 in
                                                            do {
                                                            let meta_r := Atp.as_metadata as_url iss as_body;
                                                            match meta_r {
                                                                Result.err e => IO.pure (Result.err e),
                                                                Result.ok _meta => do {
                                                                    let jwks_uri :=
                                                                        match Json.parse as_body {
                                                                            Result.ok j =>
                                                                                match Json.get_object j {
                                                                                    Result.ok o =>
                                                                                        match Json.object_get "jwks_uri" o {
                                                                                            Option.some v => match Json.get_str v { Result.ok s => Option.some s, Result.err _ => Option.none },
                                                                                            Option.none => Option.none
                                                                                        },
                                                                                    Result.err _ => Option.none
                                                                                },
                                                                            Result.err _ => Option.none
                                                                        };
                                                                    match jwks_uri {
                                                                        Option.none => IO.pure (Result.err "the AS names no jwks_uri"),
                                                                        Option.some uri0 =>
                                                                            let uri : String := uri0 in
                                                                            if Bool.not (is_https uri)
                                                                            then IO.pure (Result.err "the jwks_uri is not secure")
                                                                            else do {
                                                                                match Jwt.parse token {
                                                                                    Result.err _ => IO.pure (Result.err "the token is not a JWT"),
                                                                                    Result.ok t => do {
                                                                                        let jwks_r <- fetch_text d uri;
                                                                                        match jwks_r {
                                                                                            Result.err e => IO.pure (Result.err (String.concat "JWKS: " e)),
                                                                                            Result.ok jwks_body =>
                                                                                                match Json.parse jwks_body {
                                                                                                    Result.err _ => IO.pure (Result.err "the JWKS is not JSON"),
                                                                                                    Result.ok jwks => do {
                                                                                                        let verified <- Jwt.verify d.verifier jwks t;
                                                                                                        match verified {
                                                                                                            Result.err _ => IO.pure (Result.err "the token signature is not valid"),
                                                                                                            Result.ok _ => IO.pure (Result.ok doc)
                                                                                                        }
                                                                                                    }
                                                                                                }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                        }
                                }
                            }
                }
            }
    }
}
