// The co-op room policy's tests: codes, join seats, expiry, leave, and the
// relay's routing. These rules decide what a player sees ("room full", "no
// such room") and whether a peer can drive the other side, so they are pinned
// here rather than left to the socket glue.
//
// `let x := (match ...) in` does not parse (PLAN.md's gotcha table), so every
// "run this and take the table out" is a named helper below instead.

use lib::{
    RoomTable, rooms_new, rooms_list, rooms_count, rooms_max, room_idle_ms,
    room_find, room_expire, room_touch, room_create, room_join, room_leave, room_peer,
    room_code, room_host, room_guest, room_has_guest,
    code_digits, fresh_code, fresh_code_code, fresh_code_seq,
    created_table, created_code, joined_table, joined_host,
    TicketTable, tickets_new, tickets_count, ticket_list, tickets_max, ticket_ttl_ms,
    ticket_mint, minted_table, minted_token, ticket_consume, consumed_table, consumed_subject,
    ticket_sweep, i64_text,
    RelayAction, relay_from_host, relay_from_guest, host_left, guest_left, role_valid,
    NetMsg, wire_neutral, wire_state, wire_hero, net_encode, net_decode, msg_type, code_valid,
    code_of,
    Ticket, Room
}

// ── Helpers ─────────────────────────────────────────────────────────

/// The code a fresh room gets.
def code_at_seq (n : I64) : String :=
    let t : RoomTable := { rooms := List.empty, seq := n : RoomTable } in
    match fresh_code t {
        Option.none => "",
        Option.some f => fresh_code_code f
    }

/// A table holding one room hosted by `host`, or the empty table.
def make_room (host : String) (now : I64) : RoomTable :=
    match room_create rooms_new host now {
        Result.err _ => rooms_new,
        Result.ok c => created_table c
    }

def one_room (now : I64) : RoomTable := make_room "ana" now

/// The first room's code in `t`, or "".
def only_code (t : RoomTable) : String :=
    match List.first (rooms_list t) {
        Option.none => "",
        Option.some r => room_code r
    }

/// `t` with `guest` in the first room's seat.
def with_guest (t : RoomTable) (guest : String) (now : I64) : RoomTable :=
    match room_join t (only_code t) guest now {
        Result.err _ => t,
        Result.ok j => joined_table j
    }

def guest_of (t : RoomTable) : Option String :=
    match room_find t (only_code t) {
        Option.none => Option.none,
        Option.some r => room_guest r
    }

def host_of (t : RoomTable) : String :=
    match room_find t (only_code t) {
        Option.none => "",
        Option.some r => room_host r
    }

def has_guest (t : RoomTable) : Bool :=
    match room_find t (only_code t) {
        Option.none => false,
        Option.some r => room_has_guest r
    }

def room_exists (t : RoomTable) (code : String) : Bool :=
    match room_find t code {
        Option.none => false,
        Option.some _ => true
    }

// ── Codes ───────────────────────────────────────────────────────────

#[test]
def test_code_digits_are_four : Bool :=
    List.length (code_digits 0) == 4 && List.length (code_digits 12345) == 4

/// The generator's codes are valid codes: the two halves cannot drift.
#[test]
def test_generated_codes_are_valid : Bool :=
    code_valid (code_at_seq 0) && code_valid (code_at_seq 1) && code_valid (code_at_seq 99)

/// `fresh_code` gives a code and advances the counter past it.
#[test]
def test_fresh_code_advances_the_counter : Bool :=
    match fresh_code rooms_new {
        Option.none => false,
        Option.some f0 =>
            let f : lib::FreshCode := f0 in
            code_valid (fresh_code_code f) && fresh_code_seq f == 1
    }

/// Consecutive rooms get different codes (a guest typing one lands in one
/// room, not two).
#[test]
def test_rooms_get_distinct_codes : Bool :=
    match room_create (one_room 0) "bo" 0 {
        Result.err _ => false,
        Result.ok c2 =>
            let c : lib::Created := c2 in
            rooms_count (created_table c) == 2 && created_code c != only_code (one_room 0)
    }

// ── Join ────────────────────────────────────────────────────────────

#[test]
def test_a_guest_joins_an_empty_room : Bool :=
    let t : RoomTable := one_room 0 in
    match room_join t (only_code t) "bo" 10 {
        Result.err _ => false,
        Result.ok j0 =>
            let j : lib::Joined := j0 in
            joined_host j == "ana"
                && rooms_count (joined_table j) == 1
                && guest_of (joined_table j) == Option.some "bo"
    }

#[test]
def test_a_second_guest_is_refused : Bool :=
    let t : RoomTable := with_guest (one_room 0) "bo" 10 in
    match room_join t (only_code t) "cy" 20 {
        Result.err e => e == "room_full",
        Result.ok _ => false
    }

/// The same guest re-joining (a reconnect) is accepted, not "room full".
#[test]
def test_the_same_guest_may_rejoin : Bool :=
    let t : RoomTable := with_guest (one_room 0) "bo" 10 in
    match room_join t (only_code t) "bo" 20 {
        Result.err _ => false,
        Result.ok j0 =>
            let j : lib::Joined := j0 in
            joined_host j == "ana" && rooms_count (joined_table j) == 1
    }

#[test]
def test_joining_an_unknown_room_fails : Bool :=
    match room_join (one_room 0) "zzzz" "bo" 10 {
        Result.err e => e == "no_such_room",
        Result.ok _ => false
    }

// ── Expiry and limits ───────────────────────────────────────────────

#[test]
def test_an_idle_room_expires : Bool :=
    let t : RoomTable := one_room 0 in
    let code : String := only_code t in
    let fresh : RoomTable := room_expire t (I64.sub room_idle_ms 1) room_idle_ms in
    let stale : RoomTable := room_expire t (I64.add room_idle_ms 1) room_idle_ms in
    rooms_count fresh == 1 && rooms_count stale == 0 && Bool.not (room_exists stale code)

#[test]
def test_a_touch_keeps_a_room_alive : Bool :=
    let t : RoomTable := one_room 0 in
    let touched : RoomTable := room_touch t (only_code t) 1000 in
    rooms_count (room_expire touched (I64.add 1000 (I64.sub room_idle_ms 1)) room_idle_ms) == 1

/// A room with `code` (no `room_create`, so the bound test does not depend on
/// the code generator's spread).
def fake_room (code : String) : Room :=
    { code := code, host := "fill", guest := Option.none, seen_ms := 0 : Room }

/// `n` distinct-code rooms, so a table can be filled to the limit directly.
#[terminating]
def fill_rooms (n : I64) (acc : List Room) : List Room :=
    if n <= 0 then acc
    else
        let code : String := code_of [n, I64.add n 1, I64.add n 2, I64.add n 3] in
        fill_rooms (I64.sub n 1) (List.cons (fake_room code) acc)

#[test]
def test_the_room_table_is_bounded : Bool :=
    let t : RoomTable := { rooms := fill_rooms rooms_max List.empty, seq := 0 : RoomTable } in
    rooms_count t == rooms_max
        && (match room_create t "zed" 0 {
            Result.err e => e == "room_limit",
            Result.ok _ => false
        })

// ── Leave ───────────────────────────────────────────────────────────

/// A host leaving ends the room for both.
#[test]
def test_the_host_leaving_closes_the_room : Bool :=
    let t : RoomTable := with_guest (one_room 0) "bo" 10 in
    let code : String := only_code t in
    let after : RoomTable := room_leave t code "ana" in
    rooms_count after == 0 && Bool.not (room_exists after code)

/// A guest leaving only frees the seat: the host's room survives.
#[test]
def test_a_guest_leaving_frees_the_seat : Bool :=
    let t : RoomTable := with_guest (one_room 0) "bo" 10 in
    let after : RoomTable := room_leave t (only_code t) "bo" in
    rooms_count after == 1 && Bool.not (has_guest after) && host_of after == "ana"

// ── Peer lookup ─────────────────────────────────────────────────────

#[test]
def test_each_side_sees_the_other : Bool :=
    let t : RoomTable := with_guest (one_room 0) "bo" 10 in
    let code : String := only_code t in
    room_peer t code "ana" == Option.some "bo"
        && room_peer t code "bo" == Option.some "ana"
        && room_peer t code "cy" == Option.none
        && room_peer t "zzzz" "ana" == Option.none

// ── Tickets ─────────────────────────────────────────────────────────

#[test]
def test_i64_text_matches_to_string : Bool :=
    i64_text 0 == "0" && i64_text 7 == "7" && i64_text 42 == "42"
        && i64_text 1000 == "1000" && i64_text (0 - 15) == "-15"

#[test]
def test_a_ticket_is_single_use : Bool :=
    match ticket_mint tickets_new "ana" "abc123" 0 {
        Result.err _ => false,
        Result.ok m0 =>
            let m : lib::Minted := m0 in
            let t1 : TicketTable := minted_table m in
            let token : String := minted_token m in
            match ticket_consume t1 token 10 {
                Result.err _ => false,
                Result.ok c0 =>
                    let c : lib::Consumed := c0 in
                    consumed_subject c == "ana"
                        && tickets_count (consumed_table c) == 0
                        && (match ticket_consume (consumed_table c) token 10 {
                            Result.err e => e == "invalid_ticket",
                            Result.ok _ => false
                        })
            }
    }

#[test]
def test_a_ticket_expires : Bool :=
    match ticket_mint tickets_new "ana" "abc123" 0 {
        Result.err _ => false,
        Result.ok m0 =>
            let m : lib::Minted := m0 in
            match ticket_consume (minted_table m) (minted_token m) (I64.add ticket_ttl_ms 1) {
                Result.err e => e == "invalid_ticket",
                Result.ok _ => false
            }
    }

#[test]
def test_two_tickets_in_the_same_millisecond_differ : Bool :=
    match ticket_mint tickets_new "ana" "aaa" 0 {
        Result.err _ => false,
        Result.ok m1_0 =>
            let m1 : lib::Minted := m1_0 in
            match ticket_mint (minted_table m1) "bo" "bbb" 0 {
                Result.err _ => false,
                Result.ok m2_0 =>
                    let m2 : lib::Minted := m2_0 in
                    minted_token m1 != minted_token m2
            }
    }

#[test]
def test_a_ticket_needs_entropy : Bool :=
    match ticket_mint tickets_new "ana" "" 0 {
        Result.err e => e == "no_entropy",
        Result.ok _ => false
    }

#[terminating]
def fill_tickets (n : I64) (acc : List Ticket) : List Ticket :=
    if n <= 0 then acc
    else
        let tk : Ticket := { token := i64_text n, subject := "s", expires_ms := 1000 : Ticket } in
        fill_tickets (I64.sub n 1) (List.cons tk acc)

#[test]
def test_the_ticket_table_is_bounded : Bool :=
    let t : TicketTable := { tickets := fill_tickets tickets_max List.empty, seq := 0 : TicketTable } in
    match ticket_mint t "ana" "x" 0 {
        Result.err e => e == "too_many_tickets",
        Result.ok _ => false
    }

#[test]
def test_the_sweep_drops_expired_tickets_only : Bool :=
    match ticket_mint tickets_new "ana" "old" 0 {
        Result.err _ => false,
        Result.ok m1_0 =>
            let m1 : lib::Minted := m1_0 in
            match ticket_mint (minted_table m1) "bo" "new" (I64.sub ticket_ttl_ms 1) {
                Result.err _ => false,
                Result.ok m2_0 =>
                    let m2 : lib::Minted := m2_0 in
                    tickets_count (ticket_sweep (minted_table m2) (I64.add ticket_ttl_ms 1)) == 1
            }
    }

// ── Relay routing ───────────────────────────────────────────────────

def forwarded (a : RelayAction) : Bool :=
    match a {
        RelayAction.forward _ => true,
        _ => false
    }

def dropped (a : RelayAction) : Bool :=
    match a {
        RelayAction.discard => true,
        _ => false
    }

/// A representative state frame, decoded (so routing is tested on what the
/// wire actually produces).
def sample_state : Option NetMsg :=
    match net_decode (net_encode (NetMsg.state (wire_state 0 0 20 0 1.0
        (wire_hero 0.0 0.0 0.0 0.0 true) (wire_hero 1.0 0.0 0.0 0.0 true) false))) {
        Result.err _ => Option.none,
        Result.ok m => Option.some m
    }

#[test]
def test_the_host_may_send_state_and_nothing_else : Bool :=
    match sample_state {
        Option.none => false,
        Option.some st =>
            forwarded (relay_from_host st)
                && dropped (relay_from_host (NetMsg.intent wire_neutral))
                && dropped (relay_from_host NetMsg.create)
                && dropped (relay_from_host (NetMsg.join "ab3d"))
                && dropped (relay_from_host (NetMsg.welcome "ab3d" "host" "x"))
    }

#[test]
def test_the_guest_may_send_intent_and_nothing_else : Bool :=
    forwarded (relay_from_guest (NetMsg.intent wire_neutral))
        && dropped (relay_from_guest NetMsg.create)
        && dropped (relay_from_guest (NetMsg.join "ab3d"))
        && dropped (relay_from_guest (NetMsg.welcome "ab3d" "guest" "x"))
        && dropped (relay_from_guest (NetMsg.error "x" "y"))

/// A peer cannot forge the relay's own messages (`welcome`/`error`): neither
/// direction forwards them, whatever the sender claims to be.
#[test]
def test_the_relay_owns_welcome_and_error : Bool :=
    dropped (relay_from_host (NetMsg.welcome "ab3d" "host" "forged"))
        && dropped (relay_from_guest (NetMsg.welcome "ab3d" "guest" "forged"))
        && dropped (relay_from_host (NetMsg.error "invalid_ticket" "forged"))
        && dropped (relay_from_guest (NetMsg.error "invalid_ticket" "forged"))

#[test]
def test_a_leave_is_forwarded_both_ways : Bool :=
    forwarded (relay_from_host (NetMsg.left "bye"))
        && forwarded (relay_from_guest (NetMsg.left "bye"))

#[test]
def test_the_relay_s_closing_messages_are_lefts : Bool :=
    msg_type host_left == "left" && msg_type guest_left == "left"
        && (match net_decode (net_encode host_left) {
            Result.ok m => msg_type m == "left",
            Result.err _ => false
        })

#[test]
def test_roles_are_the_two_known_ones : Bool :=
    role_valid "host" && role_valid "guest"
        && Bool.not (role_valid "admin") && Bool.not (role_valid "")
