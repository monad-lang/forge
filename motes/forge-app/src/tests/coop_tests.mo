// The client's co-op decisions: URL building, send rates, role adoption, what
// an incoming frame does, and when the peer counts as gone. Pure, so none of
// this needs a browser.

use lib::coop {
    CoopRole, is_solo, is_host, is_guest, role_code, role_peer,
    ws_origin, socket_url, state_every, intent_every, state_ready, intent_ready,
    Coop, coop_new, coop_role, coop_url, coop_notice, coop_state, coop_guest_intent,
    coop_pending_code, peer_gone, display_code, peer_quiet,
    with_code, with_url, with_notice, failed, hello, create_msg, join_msg, bad_code_notice,
    welcomed, ended, received, received_msg, heard_state, heard_intent, tick,
    state_due, intent_due, sent, guest_ready, state_line, state_line_of
}
use forge_online::{
    NetMsg, WireState, WireIntent, wire_state, wire_hero, wire_intent, wire_neutral,
    net_encode, net_decode, coop_version, intent_mx, intent_mz, intent_jump_held, state_level, state_sparks,
    state_player, hero_x, hero_y, state_companion, hero_z, role_host, role_guest,
    code_of
}

/// `|a - b| <= 0.0005`: what the wire's milli-units can promise. (`forge-app`
/// has no forge-math dependency, so this is the one helper the tests need.)
def near (a : F64) (b : F64) : Bool :=
    let d : F64 := if a < b then b - a else a - b in
    d <= 0.0005

// ── Roles ───────────────────────────────────────────────────────────

#[test]
def test_the_three_roles_are_distinguishable : Bool :=
    is_solo CoopRole.solo && Bool.not (is_host CoopRole.solo) && Bool.not (is_guest CoopRole.solo)
        && is_host (CoopRole.host "ab3d" "kim") && Bool.not (is_guest (CoopRole.host "ab3d" "kim"))
        && is_guest (CoopRole.guest "ab3d" "ana") && Bool.not (is_host (CoopRole.guest "ab3d" "ana"))

#[test]
def test_a_role_carries_its_code_and_peer : Bool :=
    role_code (CoopRole.host "ab3d" "kim") == "ab3d"
        && role_peer (CoopRole.host "ab3d" "kim") == "kim"
        && role_code (CoopRole.guest "xy9z" "ana") == "xy9z"
        && role_peer (CoopRole.guest "xy9z" "ana") == "ana"
        && role_code CoopRole.solo == "" && role_peer CoopRole.solo == ""

// ── The URL ─────────────────────────────────────────────────────────

#[test]
def test_an_http_origin_becomes_ws : Bool :=
    ws_origin "http://127.0.0.1:8080" == "ws://127.0.0.1:8080"
        && socket_url "http://127.0.0.1:8080" "/api/ws/abc" == "ws://127.0.0.1:8080/api/ws/abc"

/// An https page must get `wss`, or the browser refuses the connection as
/// mixed content.
#[test]
def test_an_https_origin_becomes_wss : Bool :=
    ws_origin "https://forge.example" == "wss://forge.example"
        && socket_url "https://forge.example" "/api/ws/abc" == "wss://forge.example/api/ws/abc"

#[test]
def test_an_already_socket_origin_is_kept : Bool :=
    ws_origin "ws://x" == "ws://x" && ws_origin "wss://x" == "wss://x"

#[test]
def test_a_bare_origin_defaults_to_ws : Bool :=
    ws_origin "example.org" == "ws://example.org"

// ── Send rates ──────────────────────────────────────────────────────

/// A state is due once four frames have passed since the last one -- not on
/// frame 0 of the counter, which is what `sent` writes: that bug doubled the
/// send rate by sending again the frame after every send.
#[test]
def test_state_frames_are_every_fourth : Bool :=
    state_every == 4
        && Bool.not (state_ready 0) && Bool.not (state_ready 1) && Bool.not (state_ready 2)
        && Bool.not (state_ready 3) && state_ready 4 && state_ready 100

#[test]
def test_intent_frames_are_every_third : Bool :=
    intent_every == 3
        && Bool.not (intent_ready 0) && Bool.not (intent_ready 1) && Bool.not (intent_ready 2)
        && intent_ready 3 && intent_ready 99

/// A session adopted in its first frame sends at once, so a guest has
/// something to draw immediately (`coop_new` starts the counter at its
/// interval).
#[test]
def test_the_first_frame_sends : Bool :=
    state_due { coop_new with role := CoopRole.host "ab3d" "kim" }
        && intent_due { coop_new with role := CoopRole.guest "ab3d" "ana" }

/// A solo page never sends.
#[test]
def test_a_solo_page_sends_nothing : Bool :=
    Bool.not (state_due coop_new) && Bool.not (intent_due coop_new)

/// A guest sends intent, never state; a host the other way round.
#[test]
def test_the_roles_send_opposite_ways : Bool :=
    let h : Coop := { coop_new with role := CoopRole.host "ab3d" "kim" } in
    let g : Coop := { coop_new with role := CoopRole.guest "ab3d" "ana" } in
    state_due h && Bool.not (intent_due h) && intent_due g && Bool.not (state_due g)

/// After a send the counter restarts, so the next send is a full interval
/// away -- and the frame right after a send is NOT a send frame (the modulo
/// rule used to make it one).
#[test]
def test_sending_restarts_the_counter : Bool :=
    let h : Coop := sent { coop_new with role := CoopRole.host "ab3d" "kim", since_send := 9 } in
    Bool.not (state_due h) && Bool.not (state_due (tick h))
        && state_due (tick (tick (tick (tick h))))

/// Over 60 frames a host sends exactly 15 `state`s (15 Hz) and a guest 20
/// `intent`s (20 Hz) -- the rate the counters promise, checked end to end
/// through `state_due`/`intent_due`/`sent`/`tick` rather than on one frame.
#[test]
def test_sixty_frames_send_at_the_promised_rate : Bool :=
    host_sends 60 == 15 && guest_sends 60 == 20

#[terminating]
def host_sends_go (n : I64) (c : Coop) (acc : I64) : I64 :=
    if n <= 0 then acc
    else if state_due c then host_sends_go (I64.sub n 1) (tick (sent c)) (I64.add acc 1)
    else host_sends_go (I64.sub n 1) (tick c) acc

#[terminating]
def guest_sends_go (n : I64) (c : Coop) (acc : I64) : I64 :=
    if n <= 0 then acc
    else if intent_due c then guest_sends_go (I64.sub n 1) (tick (sent c)) (I64.add acc 1)
    else guest_sends_go (I64.sub n 1) (tick c) acc

// A session starts its counter at the interval (`coop_new`), so frame 0 is a
// send frame and 60 frames of a host holds 1 + 60/4 = 15 sends.
def host_sends (n : I64) : I64 :=
    host_sends_go n { coop_new with role := CoopRole.host "ab3d" "kim" } 0

def guest_sends (n : I64) : I64 :=
    guest_sends_go n { coop_new with role := CoopRole.guest "ab3d" "ana" } 0

// ── Transitions ─────────────────────────────────────────────────────

#[test]
def test_a_ticket_url_is_kept : Bool :=
    let c : Coop := with_url coop_new "ws://x/api/ws/t" in
    coop_url c == "ws://x/api/ws/t" && is_solo (coop_role c)

#[test]
def test_hello_carries_the_version_and_name : Bool :=
    let decoded : Result String NetMsg := net_decode (hello coop_new "ana") in
    match decoded {
        Result.err _ => false,
        Result.ok m =>
            match m {
                NetMsg.hello v n => v == coop_version && n == "ana",
                _ => false
            }
    }

#[test]
def test_create_is_a_create : Bool :=
    let decoded : Result String NetMsg := net_decode create_msg in
    match decoded {
        Result.ok m =>
            match m {
                NetMsg.create => true,
                _ => false
            },
        Result.err _ => false
    }

#[test]
def test_a_well_formed_code_builds_a_join : Bool :=
    let c : Coop := with_code coop_new " AB3D " in
    match join_msg c {
        Option.none => false,
        Option.some text =>
            let decoded : Result String NetMsg := net_decode text in
            match decoded {
                Result.ok m =>
                    match m {
                        // Normalized to the wire's lower case.
                        NetMsg.join code => code == "ab3d",
                        _ => false
                    },
                Result.err _ => false
            }
    }

#[test]
def test_a_malformed_code_builds_no_message : Bool :=
    join_msg (with_code coop_new "!!") == Option.none
        && join_msg (with_code coop_new "") == Option.none
        && join_msg (with_code coop_new "tooolong") == Option.none

// ── Welcome, leave, refusal ─────────────────────────────────────────

#[test]
def test_a_welcome_adopts_the_host_role : Bool :=
    let c : Coop := received coop_new (net_encode (NetMsg.welcome "ab3d" role_host "kim")) in
    is_host (coop_role c) && display_code c == "ab3d" && coop_notice c == ""

#[test]
def test_a_welcome_adopts_the_guest_role : Bool :=
    let c : Coop := received coop_new (net_encode (NetMsg.welcome "ab3d" role_guest "ana")) in
    is_guest (coop_role c) && display_code c == "ab3d"

/// A host that is told a guest joined keeps hosting: the relay's second
/// `welcome` (role `guest`) names the peer, it does not transfer the role.
#[test]
def test_a_host_keeps_its_role_when_a_guest_joins : Bool :=
    let h : Coop := received coop_new (net_encode (NetMsg.welcome "ab3d" role_host "")) in
    let after : Coop := received h (net_encode (NetMsg.welcome "ab3d" role_guest "ana")) in
    is_host (coop_role after) && display_code after == "ab3d" && role_peer (coop_role after) == "ana"

/// And a guest is not turned into a host by a stray `welcome`.
#[test]
def test_a_guest_keeps_its_role : Bool :=
    let g : Coop := received coop_new (net_encode (NetMsg.welcome "ab3d" role_guest "kim")) in
    let after : Coop := received g (net_encode (NetMsg.welcome "ab3d" role_host "kim")) in
    is_guest (coop_role after)

#[test]
def test_an_unknown_role_is_refused : Bool :=
    let c : Coop := received coop_new (net_encode (NetMsg.welcome "ab3d" "admin" "x")) in
    Bool.not (is_host (coop_role c)) && Bool.not (String.length (coop_notice c) == 0)

/// A `left` from the relay ends the session: the page is solo again and shows
/// why, rather than drawing a frozen last frame as if it were live.
#[test]
def test_a_left_ends_the_session : Bool :=
    let joined : Coop := received coop_new (net_encode (NetMsg.welcome "ab3d" role_guest "ana")) in
    let after : Coop := received joined (net_encode (NetMsg.left "the host left")) in
    is_solo (coop_role after) && coop_notice after == "the host left"

/// A refusal shows the relay's own message and does not pretend to be hosted.
#[test]
def test_a_refusal_shows_the_message : Bool :=
    let c : Coop := received coop_new (net_encode (NetMsg.error "room_full" "that game already has a second player")) in
    is_solo (coop_role c) && coop_notice c == "that game already has a second player"

#[test]
def test_garbage_from_the_socket_is_a_notice_not_a_crash : Bool :=
    let c : Coop := received coop_new "not json" in
    is_solo (coop_role c) && String.length (coop_notice c) > 0

// ── State and intent ────────────────────────────────────────────────

def sample_state : WireState :=
    wire_state 2 7 20 1 41.5
        (wire_hero 1.0 0.5 (0.0 - 3.0) 0.0 true)
        (wire_hero 1.0 0.5 (0.0 - 1.8) 3.14 false)
        false

/// The host's state arrives whole: counters, both poses, and the wire's
/// quantization is all that is lost.
#[test]
def test_a_state_frame_lands : Bool :=
    let guest : Coop := { coop_new with role := CoopRole.guest "ab3d" "ana" } in
    let c : Coop := received guest (net_encode (NetMsg.state sample_state)) in
    match coop_state c {
        Option.none => false,
        Option.some s0 =>
            let s : WireState := s0 in
            state_level s == 2 && state_sparks s == 7
                && near (hero_x (state_player s)) 1.0
                && near (hero_z (state_companion s)) (0.0 - 1.8)
    }

/// A state frame is what proves the host is alive, so it clears the quiet
/// timer even when no intent has arrived.
#[test]
def test_a_state_frame_clears_the_quiet_timer : Bool :=
    let guest : Coop := { coop_new with role := CoopRole.guest "ab3d" "ana" } in
    let aged : Coop := tick (tick guest) in
    let c : Coop := received aged (net_encode (NetMsg.state sample_state)) in
    Bool.not (peer_gone c)
        && (match coop_state c { Option.none => false, Option.some _ => true })

#[test]
def test_a_guest_intent_lands : Bool :=
    let host : Coop := { coop_new with role := CoopRole.host "ab3d" "kim" } in
    let sent_intent : WireIntent := wire_intent 0.5 (0.0 - 0.25) false true false false false false in
    let c : Coop := received host (net_encode (NetMsg.intent sent_intent)) in
    match coop_guest_intent c {
        Option.none => false,
        Option.some i0 =>
            let i : WireIntent := i0 in
            near (intent_mx i) 0.5 && near (intent_mz i) (0.0 - 0.25)
                && intent_jump_held i
    }

/// A host has no guest until an intent arrives, and knows it.
#[test]
def test_a_fresh_host_has_no_guest_input : Bool :=
    let host : Coop := { coop_new with role := CoopRole.host "ab3d" "" } in
    Bool.not (guest_ready host)

#[test]
def test_a_host_with_an_intent_has_a_guest : Bool :=
    let host : Coop := heard_intent { coop_new with role := CoopRole.host "ab3d" "kim" } wire_neutral in
    guest_ready host

// ── Quiet peer ──────────────────────────────────────────────────────

/// A guest that stops sending is detected after `peer_quiet` frames, and not
/// before.
#[test]
def test_a_quiet_guest_is_detected_at_the_boundary : Bool :=
    let start : Coop := { coop_new with role := CoopRole.host "ab3d" "kim" } in
    Bool.not (peer_gone (aged_n start peer_quiet))
        && peer_gone (aged_n start (I64.add peer_quiet 1))

#[terminating]
def aged_n (c : Coop) (n : I64) : Coop :=
    if n <= 0 then c else aged_n (tick c) (I64.sub n 1)

/// A guest does not report its host as "gone" while state still arrives.
#[test]
def test_an_idle_guest_does_not_claim_its_host_left : Bool :=
    let guest : Coop := { coop_new with role := CoopRole.guest "ab3d" "ana" } in
    matched_frame guest

def matched_frame (g : Coop) : Bool :=
    Bool.not (peer_gone (received g (net_encode (NetMsg.state sample_state))))

// ── HUD ─────────────────────────────────────────────────────────────

#[test]
def test_a_guest_with_no_state_says_so : Bool :=
    state_line (coop_new) == "waiting for the host"

#[test]
def test_a_state_line_names_the_level_and_sparks : Bool :=
    let c : Coop := heard_state coop_new sample_state in
    String.contains (state_line c) "level 3" && String.contains (state_line c) "7/20"
