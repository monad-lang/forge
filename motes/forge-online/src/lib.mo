// forge-online: the pure browser/broker contract for sign-in.
//
// Nothing here touches a socket, a cookie or a token. The page renders what
// `/api/me` returns, the broker builds it, and both use these types and paths.

pub use lib::identity {
    Provider, provider_name, provider_label, provider_of,
    Identity, identity_make, identity_provider, identity_subject, identity_display,
    identity_avatar, identity_has_avatar, identity_valid,
    display_max, avatar_max, sanitize_display, sanitize_avatar,
    identity_to_json, identity_of_json,
    Whoami, whoami_make, whoami_identity, whoami_expires_at, whoami_csrf,
    whoami_to_json, whoami_of_json, whoami_encode, whoami_decode,
    ProvidersInfo, providers_make, providers_list, providers_scope, providers_client_name,
    providers_info_to_json, providers_info_of_json, providers_info_encode,
    providers_info_decode
}

pub use lib::api {
    path_providers, path_me, path_logout, path_atproto_session, path_client_metadata,
    path_healthz, path_auth_error, path_dev_session, path_dev_auth, path_ws_ticket,
    provider_start_path, provider_callback_path,
    err_invalid_request, err_unauthorized, err_forbidden, err_invalid_csrf,
    err_invalid_dpop_proof, err_invalid_token, err_identity_mismatch,
    err_provider_unavailable, err_rate_limited, err_not_found, err_method_not_allowed,
    error_json
}
