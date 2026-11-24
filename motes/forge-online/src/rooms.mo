// forge-online: the co-op room policy, pure and testable.
//
// The broker owns live sockets and clocks; this module owns the DECISIONS:
// what code a new room gets, whether a join is allowed, when a room dies, and
// which direction a message is forwarded in. Keeping it here means the rules
// are unit-tested natively and the service file stays thin glue.
//
// Every function is `Table -> arguments -> Table` (via a named `Copy` result
// struct), so a caller threads state and a test can drive a whole session
// deterministically without a socket or a clock.

use std::derive {derive_copy, derive_clone}
use init::copy {Copy}
use lib::net {NetMsg, code_of, code_valid, normalize_code, role_host, role_guest}

// ── Rooms ───────────────────────────────────────────────────────────

/// One room: its code, who opened it, who (if anyone) joined, and when it was
/// last active. `Copy` (immutable strings and integers).
#[derive Copy Clone]
pub struct Room {
    code : String,
    host : String,
    guest : Option String,
    seen_ms : I64
}

pub def room_code (r : Room) : String := r.code

pub def room_host (r : Room) : String := r.host

pub def room_guest (r : Room) : Option String := r.guest

pub def room_seen (r : Room) : I64 := r.seen_ms

pub def room_has_guest (r : Room) : Bool :=
    match r.guest {
        Option.none => false,
        Option.some _ => true
    }

/// Every live room, and the counter the next code is derived from. `Copy`
/// (identity: a persistent list).
pub struct RoomTable {
    rooms : List Room,
    seq : I64
}

pub instance Copy RoomTable {
    def copy (t : RoomTable) : Pair RoomTable RoomTable := Pair.pair t t
}

pub def rooms_new : RoomTable := { rooms := List.empty, seq := 0 : RoomTable }

pub def rooms_list (t : RoomTable) : List Room := t.rooms

pub def rooms_count (t : RoomTable) : I64 := List.length t.rooms

/// The most rooms the broker will hold at once (one process, one game).
pub def rooms_max : I64 := 64

/// How long a silent room survives.
pub def room_idle_ms : I64 := 300000

// ── Table helpers (one pass each: a `List` is not `Copy`) ───────────

#[terminating]
def find_go (code : String) (rs : List Room) : Option Room :=
    match rs {
        List.empty => Option.none,
        List.cons r rest => if r.code == code then Option.some r else find_go code rest
    }

pub def room_find (t : RoomTable) (code : String) : Option Room :=
    find_go (normalize_code code) t.rooms

#[terminating]
def replace_go (code : String) (r : Room) (rs : List Room) : List Room :=
    match rs {
        List.empty => List.empty,
        List.cons x rest =>
            if x.code == code then List.cons r (replace_go code r rest)
            else List.cons x (replace_go code r rest)
    }

#[terminating]
def remove_go (code : String) (rs : List Room) : List Room :=
    match rs {
        List.empty => List.empty,
        List.cons x rest =>
            if x.code == code then remove_go code rest
            else List.cons x (remove_go code rest)
    }

/// Keep the rooms still inside the idle window.
#[terminating]
def expire_go (now : I64) (idle : I64) (rs : List Room) (kept : List Room) : List Room :=
    match rs {
        List.empty => List.reverse kept,
        List.cons r rest =>
            if now - r.seen_ms > idle then expire_go now idle rest kept
            else expire_go now idle rest (List.cons r kept)
    }

/// The table with every idle room gone.
pub def room_expire (t : RoomTable) (now : I64) (idle : I64) : RoomTable :=
    { rooms := expire_go now idle t.rooms List.empty, seq := t.seq : RoomTable }

// ── Codes ───────────────────────────────────────────────────────────

/// The four digits a counter maps to. Multipliers are odd and coprime with
/// the alphabet size, so consecutive counters spread over the whole code
/// space instead of walking it one character at a time.
pub def code_digits (seq : I64) : List I64 :=
    let s : I64 := if seq < 0 then 0 - seq else seq in
    [ s, I64.add (I64.mul s 7) 3, I64.add (I64.mul s 13) 5, I64.add (I64.mul s 31) 11 ]

/// A code for `seq` that no live room already holds.
#[terminating]
def fresh_code_go (t : RoomTable) (seq : I64) (tries : I64) : Option String :=
    if tries > 64 then Option.none
    else
        let code : String := code_of (code_digits seq) in
        match find_go code t.rooms {
            Option.none => Option.some code,
            Option.some _ => fresh_code_go t (I64.add seq 1) (I64.add tries 1)
        }

/// A code for the next room, and the table's new counter.
#[derive Copy Clone]
pub struct FreshCode {
    code : String,
    seq : I64
}

pub def fresh_code_code (f : FreshCode) : String := f.code

pub def fresh_code_seq (f : FreshCode) : I64 := f.seq

pub def fresh_code (t : RoomTable) : Option FreshCode :=
    match fresh_code_go t t.seq 0 {
        Option.none => Option.none,
        Option.some code =>
            let next : I64 := I64.add t.seq 1 in
            Option.some { code := code, seq := next : FreshCode }
    }

// ── Create, join, leave ─────────────────────────────────────────────

/// The outcome of `room_create`: the table and the room's code.
#[derive Copy Clone]
pub struct Created {
    table : RoomTable,
    code : String
}

pub def created_table (c : Created) : RoomTable := c.table

pub def created_code (c : Created) : String := c.code

/// Open a room for `host`. Refuses when the broker is at its room limit.
pub def room_create (t : RoomTable) (host : String) (now : I64) : Result String Created :=
    if rooms_count t >= rooms_max
    then Result.err "room_limit"
    else
        match fresh_code t {
            Option.none => Result.err "no_code_available",
            Option.some f0 =>
                let f : FreshCode := f0 in
                let room : Room := { code := f.code, host := host, guest := Option.none,
                                     seen_ms := now : Room } in
                Result.ok
                    { table := { rooms := List.cons room t.rooms, seq := f.seq : RoomTable },
                      code := f.code
                      : Created }
        }

/// The outcome of a successful join: the table and who the host is.
#[derive Copy Clone]
pub struct Joined {
    table : RoomTable,
    host : String
}

pub def joined_table (j : Joined) : RoomTable := j.table

pub def joined_host (j : Joined) : String := j.host

/// Add `guest` to the room `code`. Distinguishes the three refusals the UI
/// shows differently: no such room, the room is full, and the room already
/// holds this same guest (a reconnect, which is accepted as a re-join).
pub def room_join (t : RoomTable) (code : String) (guest : String) (now : I64)
    : Result String Joined :=
    match room_find t code {
        Option.none => Result.err "no_such_room",
        Option.some r0 =>
            let r : Room := r0 in
            match r.guest {
                Option.some g =>
                    let g2 : String := g in
                    if g2 == guest then Result.ok { table := t, host := r.host : Joined }
                    else Result.err "room_full",
                Option.none =>
                    let joined : Room := { code := r.code, host := r.host, guest := Option.some guest,
                                           seen_ms := now : Room } in
                    Result.ok
                        { table := { rooms := replace_go r.code joined t.rooms, seq := t.seq : RoomTable },
                          host := r.host
                          : Joined }
            }
    }

/// `code`'s room, with its clock refreshed (`now`).
pub def room_touch (t : RoomTable) (code : String) (now : I64) : RoomTable :=
    match room_find t code {
        Option.none => t,
        Option.some r0 =>
            let r : Room := r0 in
            let touched : Room := { code := r.code, host := r.host, guest := r.guest, seen_ms := now : Room } in
            { rooms := replace_go r.code touched t.rooms, seq := t.seq : RoomTable }
    }

/// Drop `code`'s room if `who` is its host (a host leaving ends the room for
/// both). A guest leaving only frees the guest slot.
pub def room_leave (t : RoomTable) (code : String) (who : String) : RoomTable :=
    match room_find t code {
        Option.none => t,
        Option.some r0 =>
            let r : Room := r0 in
            if r.host == who
            then { rooms := remove_go r.code t.rooms, seq := t.seq : RoomTable }
            else
                let freed : Room := { code := r.code, host := r.host, guest := Option.none,
                                      seen_ms := r.seen_ms : Room } in
                { rooms := replace_go r.code freed t.rooms, seq := t.seq : RoomTable }
    }

/// The other side of `code`'s room from `who`, if there is one.
pub def room_peer (t : RoomTable) (code : String) (who : String) : Option String :=
    match room_find t code {
        Option.none => Option.none,
        Option.some r0 =>
            let r : Room := r0 in
            if r.host == who
            then r.guest
            else if guest_is r.guest who then Option.some r.host
            else Option.none
    }

def guest_is (g : Option String) (who : String) : Bool :=
    match g {
        Option.none => false,
        Option.some x => x == who
    }

// ── Tickets ─────────────────────────────────────────────────────────
//
// A browser cannot set a header on `WebSocket`, and a session cookie in a
// query string lands in proxy logs. So the upgrade carries a short-lived,
// single-use ticket instead, minted by an authenticated `GET /api/ws-ticket`.
//
// The token is `seq ++ "-" ++ entropy`: the counter makes two tickets in the
// same millisecond distinct, and `entropy` (real randomness from the caller)
// makes them unguessable. This module never invents randomness itself.

/// One outstanding ticket. `Copy`.
#[derive Copy Clone]
pub struct Ticket {
    token : String,
    subject : String,
    expires_ms : I64
}

pub def ticket_token (t : Ticket) : String := t.token

pub def ticket_subject (t : Ticket) : String := t.subject

pub def ticket_expires (t : Ticket) : I64 := t.expires_ms

/// Every ticket not yet used or expired, and the counter. `Copy` (identity).
pub struct TicketTable {
    tickets : List Ticket,
    seq : I64
}

pub instance Copy TicketTable {
    def copy (t : TicketTable) : Pair TicketTable TicketTable := Pair.pair t t
}

pub def tickets_new : TicketTable := { tickets := List.empty, seq := 0 : TicketTable }

pub def tickets_count (t : TicketTable) : I64 := List.length t.tickets

/// The outstanding tickets (tests and a sweep's diagnostics).
pub def ticket_list (t : TicketTable) : List Ticket := t.tickets

/// The most outstanding tickets the broker will hold (one per connect in
/// flight, plus slack; a flood is refused rather than growing the list).
pub def tickets_max : I64 := 256

/// How long a ticket lives.
pub def ticket_ttl_ms : I64 := 30000

#[terminating]
def i64_text_go (n : I64) (acc : String) : String :=
    if n < 10 then String.concat (String.slice "0123456789" n 1) acc
    else i64_text_go (I64.div n 10) (String.concat (String.slice "0123456789" (I64.rem n 10) 1) acc)

/// `n` (>= 0) in decimal, without `I64.to_string` (which the contract mote
/// can use, but this keeps the token shape obvious and testable).
pub def i64_text (n : I64) : String :=
    if n < 0 then String.concat "-" (i64_text_go (0 - n) "") else i64_text_go n ""

/// The table and the token just minted.
#[derive Copy Clone]
pub struct Minted {
    table : TicketTable,
    token : String
}

pub def minted_table (m : Minted) : TicketTable := m.table

pub def minted_token (m : Minted) : String := m.token

/// Mint a ticket for `subject`, using `entropy` (caller-supplied randomness).
pub def ticket_mint (t : TicketTable) (subject : String) (entropy : String) (now : I64)
    : Result String Minted :=
    if Bool.not (String.length entropy > 0)
    then Result.err "no_entropy"
    else if tickets_count t >= tickets_max
    then Result.err "too_many_tickets"
    else
        let seq : I64 := t.seq in
        let token : String :=
            String.concat (i64_text seq) (String.concat "-" entropy) in
        let ticket : Ticket := { token := token, subject := subject,
                                 expires_ms := I64.add now ticket_ttl_ms : Ticket } in
        Result.ok
            { table := { tickets := List.cons ticket t.tickets, seq := I64.add seq 1 : TicketTable },
              token := token
              : Minted }

#[terminating]
def ticket_take_go (token : String) (now : I64) (ts : List Ticket) (kept : List Ticket)
    (found : Option Ticket) : Pair (List Ticket) (Option Ticket) :=
    match ts {
        List.empty => Pair.pair (List.reverse kept) found,
        List.cons tk rest =>
            if tk.token == token && tk.expires_ms > now
            then ticket_take_go token now rest kept (Option.some tk)
            else if tk.expires_ms > now
            then ticket_take_go token now rest (List.cons tk kept) found
            else ticket_take_go token now rest kept found
    }

/// The table after consuming `token`, and whose it was.
#[derive Copy Clone]
pub struct Consumed {
    table : TicketTable,
    subject : String
}

pub def consumed_table (c : Consumed) : TicketTable := c.table

pub def consumed_subject (c : Consumed) : String := c.subject

/// Spend `token`: it is removed whether or not it was expired (an expired
/// ticket is dead either way), and the subject comes back only when it was
/// live. Single use is the point: a replayed ticket finds nothing.
pub def ticket_consume (t : TicketTable) (token : String) (now : I64)
    : Result String Consumed :=
    match ticket_take_go token now t.tickets List.empty Option.none {
        Pair.pair kept found =>
            let table : TicketTable := { tickets := kept, seq := t.seq : TicketTable } in
            match found {
                Option.none => Result.err "invalid_ticket",
                Option.some tk0 =>
                    let tk : Ticket := tk0 in
                    Result.ok { table := table, subject := tk.subject : Consumed }
            }
    }

/// The table with expired tickets dropped (a periodic sweep).
pub def ticket_sweep (t : TicketTable) (now : I64) : TicketTable :=
    { tickets := ticket_live_go t.tickets now List.empty, seq := t.seq : TicketTable }

#[terminating]
def ticket_live_go (ts : List Ticket) (now : I64) (kept : List Ticket) : List Ticket :=
    match ts {
        List.empty => List.reverse kept,
        List.cons tk rest =>
            if tk.expires_ms > now then ticket_live_go rest now (List.cons tk kept)
            else ticket_live_go rest now kept
    }

// ── Relay routing ───────────────────────────────────────────────────
//
// The relay is dumb on purpose: it decides only which direction a message
// goes, never what a message means. Anything unexpected is refused, so a peer
// cannot drive the other side with a message only the relay should send
// (`welcome`, `error`).

/// What the relay does with one message. `Copy`.
#[derive Copy Clone]
pub type RelayAction {
    /// Forward to the other peer in the room.
    forward (m : NetMsg),
    /// Hand it back to the sender.
    refuse (code : String) (message : String),
    /// Nothing to do.
    discard
}

/// A message from the room's host.
pub def relay_from_host (m : NetMsg) : RelayAction :=
    match m {
        NetMsg.state _ => RelayAction.forward m,
        NetMsg.left _ => RelayAction.forward m,
        _ => RelayAction.discard
    }

/// A message from the room's guest.
pub def relay_from_guest (m : NetMsg) : RelayAction :=
    match m {
        NetMsg.intent _ => RelayAction.forward m,
        NetMsg.left _ => RelayAction.forward m,
        _ => RelayAction.discard
    }

/// The message a guest gets when the host's socket closes.
pub def host_left : NetMsg := NetMsg.left "the host left"

/// The message a host gets when the guest's socket closes.
pub def guest_left : NetMsg := NetMsg.left "the guest left"

/// Is `role` the string a `welcome` may carry?
pub def role_valid (role : String) : Bool := role == role_host || role == role_guest
