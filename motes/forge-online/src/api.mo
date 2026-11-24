// The broker's HTTP surface, as constants shared with the page.
//
// These strings are the contract: the browser and the broker build the same
// paths and read the same error codes, so a typo is a compile-time-adjacent
// test failure (`online_tests.mo`) rather than a 404 in a browser.

use json::json {Json, Json.to_string}
use lib::identity {Provider, provider_name}

pub def path_providers : String := "/api/providers"

pub def path_me : String := "/api/me"

pub def path_logout : String := "/api/logout"

pub def path_atproto_session : String := "/api/atproto/session"

pub def path_client_metadata : String := "/client-metadata.json"

pub def path_healthz : String := "/healthz"

pub def path_auth_error : String := "/auth/error"

pub def path_dev_session : String := "/api/dev/session"

pub def path_dev_auth : String := "/auth/dev"

pub def path_ws_ticket : String := "/api/ws-ticket"

/// The co-op socket route, as a prefix: the upgrade names its single-use
/// ticket in the last segment (`/api/ws/<ticket>`), so the route is mounted on
/// `path_ws_prefix ++ ticket`. `Ctx` exposes the path but not the query, which
/// is why the ticket travels here rather than in `?t=`.
pub def path_ws_prefix : String := "/api/ws/"

pub def provider_start_path (p : Provider) : String :=
    String.concat_list ["/auth/", provider_name p, "/start"]

pub def provider_callback_path (p : Provider) : String :=
    String.concat_list ["/auth/", provider_name p, "/callback"]

/// The error body's `error` member. Stable, machine-readable, never a
/// provider's wording.
pub def err_invalid_request : String := "invalid_request"

pub def err_unauthorized : String := "unauthorized"

pub def err_forbidden : String := "forbidden"

pub def err_invalid_csrf : String := "invalid_csrf"

pub def err_invalid_dpop_proof : String := "invalid_dpop_proof"

pub def err_invalid_token : String := "invalid_token"

pub def err_identity_mismatch : String := "identity_mismatch"

pub def err_provider_unavailable : String := "provider_unavailable"

pub def err_rate_limited : String := "rate_limited"

pub def err_not_found : String := "not_found"

pub def err_method_not_allowed : String := "method_not_allowed"

/// `{"error":"<code>","message":"<short human text>"}`. The message is ours
/// and intentionally vague about which internal check failed.
pub def error_json (code : String) (message : String) : String :=
    Json.to_string
        (Json.make_object_pairs
            [Pair.pair "error" (Json.make_str code),
             Pair.pair "message" (Json.make_str message)])
