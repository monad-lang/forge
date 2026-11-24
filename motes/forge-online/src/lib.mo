// forge-online: the pure browser/broker contract for sign-in and co-op.
//
// Nothing here touches a socket, a cookie or a token. The page renders what
// `/api/me` returns, the broker builds it, and both use these types and paths.
// `lib::net` is the co-op wire: the messages two game clients exchange
// through the relay, integer-only so both sides agree exactly.

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
    path_healthz, path_auth_error, path_dev_session, path_dev_auth, path_ws_ticket, path_ws_prefix,
    provider_start_path, provider_callback_path,
    err_invalid_request, err_unauthorized, err_forbidden, err_invalid_csrf,
    err_invalid_dpop_proof, err_invalid_token, err_identity_mismatch,
    err_provider_unavailable, err_rate_limited, err_not_found, err_method_not_allowed,
    error_json
}

pub use lib::net {
    coop_protocol, coop_version, code_len, code_alphabet, code_of, code_valid, normalize_code,
    alphabet_has,
    milli, milli_max, f64_round_i64, to_milli, of_milli, axis_to_wire, axis_of_wire,
    millis_max, to_millis, of_millis,
    WireHero, wire_hero, hero_x, hero_y, hero_z, hero_yaw, hero_grounded,
    WireState, wire_state, state_level, state_sparks, state_total, state_falls, state_seconds,
    state_player, state_companion, state_won,
    WireIntent, wire_intent, wire_neutral, intent_mx, intent_mz, intent_jump_pressed,
    intent_jump_held, intent_dash_pressed, intent_sprint, intent_ability_pressed,
    intent_swap_pressed, intent_is_neutral,
    net_max_chars, NetMsg, role_host, role_guest, msg_type, msg_to_json, net_encode, net_decode
}

pub use lib::rooms {
    Room, room_code, room_host, room_guest, room_seen, room_has_guest,
    RoomTable, rooms_new, rooms_list, rooms_count, rooms_max, room_idle_ms,
    room_find, room_expire, room_touch, room_create, room_join, room_leave, room_peer,
    code_digits, FreshCode, fresh_code_code, fresh_code_seq, fresh_code,
    Created, created_table, created_code,
    Joined, joined_table, joined_host,
    Ticket, ticket_token, ticket_subject, ticket_expires,
    TicketTable, tickets_new, tickets_count, ticket_list, tickets_max, ticket_ttl_ms,
    i64_text, Minted, minted_table, minted_token, ticket_mint,
    Consumed, consumed_table, consumed_subject, ticket_consume, ticket_sweep,
    RelayAction, relay_from_host, relay_from_guest, host_left, guest_left, role_valid
}
