// The atproto exchange without a network: synthetic JWTs, a scripted
// transport, and `JwtVerifier.fake` so the claim, replay and DID-chain rules
// run without OpenSSL. The signatures themselves are covered by the real
// verifier in the full gate.

use std::base64 {B64Url.encode}
use std::io {IO.epoch_time_nano}
use oauth::http_client {OauthHttp, OauthHttp.fake, ScriptedExchange}
use jsonwebtoken::verifier {JwtVerifier}
use atproto_oauth::dpop {Atp.dpop_ath}
use atproto_oauth::client_metadata {Atp.jwk_thumbprint}
use forge_online::identity {Identity, identity_subject}
use lib::atproto_verify {AtpDeps, VerifiedAtp, atp_deps_new, verify_exchange}

def b32 : List U8 :=
    [0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8]

def x_b64 : String := B64Url.encode b32

def y_b64 : String := B64Url.encode b32

def jwk_json : String :=
    String.concat_list ["{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"", x_b64,
        "\",\"y\":\"", y_b64, "\"}"]

def jkt : String := Atp.jwk_thumbprint x_b64 y_b64

def jwt (header : String) (payload : String) : String :=
    String.concat_list [B64Url.encode (String.to_list header), ".",
        B64Url.encode (String.to_list payload), ".",
        B64Url.encode [1u8, 2u8, 3u8]]

def url : String := "https://mo.example/api/atproto/session"

def did : String := "did:plc:abc"

def issuer : String := "https://as.example"

def now_s : IO I64 := do {
    let n <- IO.epoch_time_nano;
    IO.pure (I64.div n 1000000000i64)
}

def proof_for (token : String) (now : I64) (jti : String) (htu : String) : String :=
    let header : String := String.concat_list ["{\"typ\":\"dpop+jwt\",\"alg\":\"ES256\",\"jwk\":", jwk_json, "}"] in
    let payload : String :=
        String.concat_list ["{\"iss\":\"https://mo.example\",\"iat\":", I64.to_string now,
            ",\"jti\":\"", jti, "\",\"htm\":\"POST\",\"htu\":\"", htu,
            "\",\"ath\":\"", Atp.dpop_ath token, "\"}"] in
    jwt header payload

def token_for (now : I64) (bound : String) : String :=
    let header : String := "{\"alg\":\"ES256\",\"kid\":\"k1\"}" in
    let payload : String :=
        String.concat_list ["{\"iss\":\"", issuer, "\",\"sub\":\"", did,
            "\",\"exp\":", I64.to_string (I64.add now 300i64),
            ",\"scope\":\"atproto\",\"cnf\":{\"jkt\":\"", bound, "\"}}"] in
    jwt header payload

def did_body : String :=
    "{\"id\":\"did:plc:abc\",\"service\":[{\"id\":\"#atproto_pds\",\"type\":\"AtprotoPersonalDataServer\",\"serviceEndpoint\":\"https://pds.example\"}],\"alsoKnownAs\":[\"at://alice.test\"]}"

def prm_body : String :=
    "{\"authorization_servers\":[\"https://as.example\"]}"

def as_body : String :=
    "{\"issuer\":\"https://as.example\",\"authorization_endpoint\":\"https://as.example/auth\",\"token_endpoint\":\"https://as.example/token\",\"pushed_authorization_request_endpoint\":\"https://as.example/par\",\"jwks_uri\":\"https://as.example/keys\"}"

def jwks_body : String :=
    String.concat_list ["{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"k1\",\"x\":\"",
        x_b64, "\",\"y\":\"", y_b64, "\"}]}"]

def ex (path : String) (body : String) : ScriptedExchange :=
    { path := path, status := 200u16, body := body : ScriptedExchange }

def script : List ScriptedExchange :=
    [ ex "/did:plc:abc" did_body,
      ex "/.well-known/oauth-protected-resource" prm_body,
      ex "/.well-known/oauth-authorization-server" as_body,
      ex "/keys" jwks_body ]

def deps (gets : List ScriptedExchange) : IO AtpDeps := do {
    let http <- OauthHttp.fake gets List.empty;
    atp_deps_new http (JwtVerifier.fake true)
}

def verified_subject (r : Result String VerifiedAtp) : Option String :=
    match r {
        Result.err _ => Option.none,
        Result.ok v => Option.some (identity_subject v.identity)
    }

#[test]
def test_atproto_exchange_verifies : IO Bool := do {
    let now <- now_s;
    let token : String := token_for now jkt;
    let proof : String := proof_for token now "jti-1" url;
    let d <- deps script;
    let r <- verify_exchange d url (Option.some (String.concat "DPoP " token)) (Option.some proof);
    IO.pure (match verified_subject r { Option.some s => s == did, Option.none => false })
}

#[test]
def test_replayed_proof_is_rejected : IO Bool := do {
    let now <- now_s;
    let token : String := token_for now jkt;
    let proof : String := proof_for token now "jti-replay" url;
    let d <- deps script;
    let first <- verify_exchange d url (Option.some (String.concat "DPoP " token)) (Option.some proof);
    let second <- verify_exchange d url (Option.some (String.concat "DPoP " token)) (Option.some proof);
    IO.pure ((match first { Result.ok _ => true, Result.err _ => false })
        && (match second { Result.ok _ => false, Result.err e => String.contains e "replayed" }))
}

#[test]
def test_proof_for_another_endpoint_is_rejected : IO Bool := do {
    let now <- now_s;
    let token : String := token_for now jkt;
    let proof : String := proof_for token now "jti-htu" "https://mo.example/api/other";
    let d <- deps script;
    let r <- verify_exchange d url (Option.some (String.concat "DPoP " token)) (Option.some proof);
    IO.pure (match r { Result.ok _ => false, Result.err e => String.contains e "htu" })
}

#[test]
def test_token_bound_to_another_key_is_rejected : IO Bool := do {
    let now <- now_s;
    let token : String := token_for now "another-thumbprint";
    let proof : String := proof_for token now "jti-cnf" url;
    let d <- deps script;
    let r <- verify_exchange d url (Option.some (String.concat "DPoP " token)) (Option.some proof);
    IO.pure (match r { Result.ok _ => false, Result.err e => String.contains e "another key" })
}
