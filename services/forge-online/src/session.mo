// The broker's forge session: one opaque id in Moon's in-memory store, one
// provider identity inside it. No provider tokens are kept server-side.
//
// Production cookie is `__Host-forge_session` (Secure, HttpOnly, Lax, `/`);
// the loopback dev origin uses `forge_session` without `Secure`/`__Host-`
// (the `__Host-` prefix is illegal without Secure).
//
// CSRF is a session-bound token (`Csrf.token` = SHA-256(secret ++ id)),
// returned by `/api/me` and required as `X-CSRF-Token` on mutations.

use std::io {IO.epoch_time_nano}
use http::types {Headers, Headers.add, Request, Response}
use http::strings {Strings.ct_eq}
use moon::session {
    Session, SessionConfig, SessionStore, SessionStore.new_with,
    SessionStore.begin_checked, SessionStore.commit, SessionStore.load,
    SessionStore.destroy, Session.put, Session.get
}
use moon::session_crypto {SessionConfig.with_crypto_ids}
use moon::csrf {Csrf.token}
use forge_online::identity {
    Identity, identity_make, identity_provider, identity_subject, identity_display,
    identity_avatar, identity_valid, provider_of, provider_name, whoami_make,
    whoami_encode, Whoami, whoami_identity, whoami_expires_at, whoami_csrf
}
use lib::config {Config}

// `Session` is an immutable value (mutation goes through `SessionHandle`'s
// `Ref`); sharing it is a true copy, and the alternative is cloning the field
// list to read four members.
pub instance Copy Session {
    def copy (s : Session) : Pair Session Session := Pair.pair s s
}

pub struct ForgeSessions {
    store : SessionStore,
    secret : String,
    ttl : I64
}

// The store and the policy are immutable for a process; sharing them is the
// point (every handler talks to the same table).
pub instance Copy ForgeSessions {
    def copy (fs : ForgeSessions) : Pair ForgeSessions ForgeSessions := Pair.pair fs fs
}

// Responses are immutable values; `with_cookie_pairs` rebuilds one.
pub instance Copy Response {
    def copy (r : Response) : Pair Response Response := Pair.pair r r
}

pub def forge_sessions_new (c : Config) : IO (Result String ForgeSessions) := do {
    let cookie : String := if c.secure then "__Host-forge_session" else "forge_session";
    let ttl : I64 := 604800i64;
    let base : SessionConfig := SessionConfig.default cookie ttl;
    let sc : SessionConfig := { base with secure := c.secure };
    let sc2 : SessionConfig := SessionConfig.with_crypto_ids sc;
    let r <- SessionStore.new_with sc2;
    match r {
        Result.err e => IO.pure (Result.err e),
        Result.ok store =>
            IO.pure (Result.ok { store := store, secret := c.csrf_secret, ttl := ttl : ForgeSessions })
    }
}

pub def forge_sessions_load (fs : ForgeSessions) (req : Request) : IO (Option Session) :=
    SessionStore.load fs.store req

/// The session's store attributes as a `Whoami`. `expires_at` is epoch ms.
pub def forge_sessions_whoami (fs : ForgeSessions) (s : Session) : IO (Result String Whoami) := do {
    match forge_session_identity s {
        Result.err e => IO.pure (Result.err e),
        Result.ok id => do {
            let now <- IO.epoch_time_nano;
            let now_ms : I64 := I64.div now 1000000i64;
            let exp : I64 := I64.add now_ms (I64.mul fs.ttl 1000i64);
            IO.pure (Result.ok (whoami_make id exp (Csrf.token fs.secret s)))
        }
    }
}

def forge_session_identity (s : Session) : Result String Identity :=
    match Session.get s "p" {
        Option.none => Result.err "session has no provider",
        Option.some ps =>
            match provider_of ps {
                Result.err e => Result.err e,
                Result.ok p =>
                    match Session.get s "s" {
                        Option.none => Result.err "session has no subject",
                        Option.some subject =>
                            match Session.get s "d" {
                                Option.none => Result.err "session has no display name",
                                Option.some display =>
                                    let avatar : String :=
                                        match Session.get s "a" {
                                            Option.some a => a,
                                            Option.none => ""
                                        } in
                                    Result.ok (identity_make p subject display avatar)
                            }
                    }
            }
    }

/// Sign in: a fresh id (never a promoted pre-login one), the identity's four
/// fields, and the Set-Cookie pairs. Returns the `Whoami` the client renders.
pub def forge_sessions_sign_in (fs : ForgeSessions) (id : Identity)
    : IO (Result String (Pair Whoami (List (Pair String String)))) := do {
    if Bool.not (identity_valid id)
    then IO.pure (Result.err "identity is not valid (empty or oversized subject/display)")
    else do {
    let r <- SessionStore.begin_checked fs.store;
    match r {
        Result.err e => IO.pure (Result.err e),
        Result.ok s0 => do {
            let s1 : Session := Session.put s0 "p" (provider_name (identity_provider id));
            let s2 : Session := Session.put s1 "s" (identity_subject id);
            let s3 : Session := Session.put s2 "d" (identity_display id);
            let s4 : Session := Session.put s3 "a" (identity_avatar id);
            let w <- forge_sessions_whoami fs s4;
            match w {
                Result.err e => IO.pure (Result.err e),
                Result.ok who => do {
                    let cookies <- SessionStore.commit fs.store s4;
                    IO.pure (Result.ok (Pair.pair who cookies))
                }
            }
        }
    }
    }
}

/// Slide the session (commit refreshes expiry) and return its Set-Cookie.
pub def forge_sessions_touch (fs : ForgeSessions) (s : Session) : IO (List (Pair String String)) :=
    SessionStore.commit fs.store s

pub def forge_sessions_sign_out (fs : ForgeSessions) (req : Request) : IO (List (Pair String String)) :=
    SessionStore.destroy fs.store req

/// Constant-time check of the `X-CSRF-Token` header against the session.
pub def forge_sessions_csrf_ok (fs : ForgeSessions) (s : Session) (req : Request) : Bool :=
    match Headers.get "x-csrf-token" req.headers {
        Option.none => false,
        Option.some submitted => Strings.ct_eq (Csrf.token fs.secret s) submitted
    }

pub def with_cookie_pairs (pairs : List (Pair String String)) (res : Response) : Response :=
    match pairs {
        List.empty => res,
        List.cons p rest =>
            match p {
                Pair.pair k v => with_cookie_pairs rest { res with headers := Headers.add k v res.headers }
            }
    }

pub def whoami_json_response (status : U16) (w : Whoami) : Response :=
    Response.json status (whoami_encode w)
