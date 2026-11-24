// The broker's co-op relay. Every decision lives in `forge_online::rooms`
// (pure, tested); this file only wires sockets to it.
//
// ## Shape: one blocking reader per connection
//
// `MoonWs.handler` runs the session on the connection's own fiber with the
// live `WsConn`, so each session is a plain `Ws.recv` loop: read, decide,
// send to the peer, repeat. Nothing polls a shared inbox, and no two
// sessions can interleave a half-join, because every transition is one
// `rooms` call against the shared `Ref` table.
//
// (`WsHub` is the other shape moon offers -- a tick drains one inbox -- and
// it is the right one for a server that steps a simulation. This relay has
// no tick, so it does not need a hub, and not using one keeps a 15 Hz
// client stream from waiting on an unrelated tick.)
//
// ## Roles
//
// A connection starts `idle`. Its first message must be `hello`, then
// `create` (become a host) or `join <code>`. The relay answers `welcome`,
// then forwards:
//
//   host -> guest : `state`, `left`
//   guest -> host : `intent`, `left`
//
// Everything else is dropped. A peer cannot send `welcome` or `error`: those
// are the relay's own voice (`rooms.relay_from_host/guest`).
//
// ## The ticket
//
// A browser cannot set a header on a `WebSocket`, and a session cookie in a
// query string ends up in proxy logs. So `GET /api/ws-ticket` (session-gated)
// mints a single-use ticket and the upgrade names it as the last path segment:
// `/api/ws/<ticket>`. `Ctx` exposes the path but neither the query nor the
// URI, so a path segment is the only place the upgrade can carry it at this
// pin.
//
// ## Testing
//
// This file is socket glue and has no native test. The decisions it makes are
// covered by `rooms_tests.mo` (pure) and the client half by
// `tests/web/mo_venture_coop_smoke.mjs` against a scripted broker.

use std::derive {derive_copy, derive_clone}
use std::ref {Ref, Ref.get, Ref.set}
use http::types {Response}
use http::websocket {WsMessage, WsMessage.text_of}
use http::websocket_io {WsConn, WsConfig, Ws.recv, Ws.send, Ws.close, WsError}
use moon::context {Ctx, Ctx.path}
use moon::handler_t {HandlerT, HandlerT.run, HttpError}
use moon::websocket {MoonWs.handler}
use forge_online::{
    NetMsg, net_encode, net_decode, coop_protocol, coop_version,
    RoomTable, rooms_new, room_idle_ms, room_create, room_join, room_leave, room_expire, room_peer,
    room_touch, created_code, created_table, joined_host, joined_table, Created, Joined,
    TicketTable, tickets_new, tickets_count, ticket_consume, consumed_table, consumed_subject, Consumed,
    RelayAction, relay_from_host, relay_from_guest, host_left, guest_left
}

// ── the relay's tables ──────────────────────────────────────────────

/// One live connection: the id the room table knows it by, and its socket.
/// `Copy` (an id string and a handle).
#[derive Copy Clone]
pub struct Link {
    id : String,
    conn : WsConn
}

pub def link_id (l : Link) : String := l.id

// `WsConn` is a handle (four `Ref`s and a role): sharing it is what a socket
// session does every time it reads, decides and replies. `http::websocket_io`
// does not declare this instance at the pin, so the relay does.
pub instance Copy WsConn {
    def copy (c : WsConn) : Pair WsConn WsConn := Pair.pair c c
}

/// The relay's shared state: the pure room policy plus the sockets to reach.
pub struct Relay {
    rooms : Ref RoomTable,
    tickets : Ref TicketTable,
    conns : Ref (List Link),
    next_id : Ref I64
}

// Every field is a `Ref` handle: sharing the relay shares the tables, which
// is the point (the same reason `AppState` has an identity copy).
pub instance Copy Relay {
    def copy (r : Relay) : Pair Relay Relay := Pair.pair r r
}

/// What one connection is. `Copy`.
#[derive Copy Clone]
pub type Role {
    /// Said hello (or not yet), has no room.
    idle (name : String),
    /// Owns this room.
    hosting (code : String) (name : String),
    /// Is this room's guest.
    guesting (code : String) (name : String)
}

pub def relay_new (tickets : Ref TicketTable) : IO Relay := do {
    let rooms <- Ref.new rooms_new;
    let conns <- Ref.new (List.empty : List Link);
    let next_id <- Ref.new 1i64;
    IO.pure { rooms := rooms, tickets := tickets, conns := conns, next_id := next_id : Relay }
}

pub def now_ms : IO I64 := do {
    let now <- IO.current_time;
    IO.pure now
}

// ── the connection registry ────────────────────────────────────────

#[terminating]
def find_link_go (id : String) (ls : List Link) : Option Link :=
    match ls {
        List.empty => Option.none,
        List.cons l rest => if l.id == id then Option.some l else find_link_go id rest
    }

def relay_find (r : Relay) (id : String) : IO (Option WsConn) := do {
    let ls <- Ref.get r.conns;
    match find_link_go id ls {
        Option.none => IO.pure Option.none,
        Option.some l => IO.pure (Option.some l.conn)
    }
}

def relay_register (r : Relay) (id : String) (conn : WsConn) : IO Unit := do {
    let ls <- Ref.get r.conns;
    Ref.set r.conns (List.cons { id := id, conn := conn : Link } ls)
}

#[terminating]
def without_go (id : String) (ls : List Link) (kept : List Link) : List Link :=
    match ls {
        List.empty => List.reverse kept,
        List.cons l rest =>
            if l.id == id then without_go id rest kept
            else without_go id rest (List.cons l kept)
    }

def relay_unregister (r : Relay) (id : String) : IO Unit := do {
    let ls <- Ref.get r.conns;
    Ref.set r.conns (without_go id ls List.empty)
}

// ── sending ─────────────────────────────────────────────────────────

/// Send one message to one connection. A failed send ends that connection:
/// its own reader loop reports the close, so this only has to stop writing.
def ws_send (conn : WsConn) (m : NetMsg) : IO Bool := do {
    let text : String := net_encode m;
    let r <- Ws.send conn (WsMessage.text text);
    match r {
        Result.ok _ => IO.pure true,
        Result.err _ => IO.pure false
    }
}

/// Send to whoever is on the other side of `code`'s room from `who`. The
/// send is best effort: a peer that has gone away is cleaned up by its own
/// session, not here.
def send_peer (r : Relay) (code : String) (who : String) (m : NetMsg) : IO Unit := do {
    let table <- Ref.get r.rooms;
    match room_peer table code who {
        Option.none => IO.pure unit,
        Option.some peer_id => do {
            let target <- relay_find r peer_id;
            match target {
                Option.none => IO.pure unit,
                Option.some conn => do {
                    let _ <- ws_send conn m;
                    IO.pure unit
                }
            }
        }
    }
}

// ── room lifecycle ──────────────────────────────────────────────────

/// Mint a room for `id` and answer `welcome` with its code.
def do_create (r : Relay) (id : String) (conn : WsConn) (name : String) : IO Role := do {
    let now <- now_ms;
    let table <- Ref.get r.rooms;
    let live : RoomTable <- IO.pure (room_expire table now room_idle_ms);
    match room_create live id now {
        Result.err e => do_create_failed conn name e,
        Result.ok c0 => do_create_ok r id conn name c0
    }
}

def do_create_failed (conn : WsConn) (name : String) (e : String) : IO Role := do {
    let _ <- ws_send conn (NetMsg.error e "could not open a room");
    IO.pure (Role.idle name)
}

def do_create_ok (r : Relay) (id : String) (conn : WsConn) (name : String) (c0 : Created)
    : IO Role := do {
    let code : String <- IO.pure (created_code c0);
    let _ <- Ref.set r.rooms (created_table c0);
    let _ <- ws_send conn (NetMsg.welcome code "host" "");
    IO.pure (Role.hosting code name)
}

/// Seat `id` as `code`'s guest, answer `welcome`, and tell the host who
/// joined.
def do_join (r : Relay) (id : String) (conn : WsConn) (name : String) (code : String)
    : IO Role := do {
    let now <- now_ms;
    let table <- Ref.get r.rooms;
    match room_join table code id now {
        Result.err e => do_join_failed conn name e,
        Result.ok j0 => do_join_ok r conn name code j0
    }
}

/// The join refusal, with the message the panel shows.
def do_join_failed (conn : WsConn) (name : String) (e : String) : IO Role := do {
    let message : String :=
        if e == "no_such_room" then "no game with that code"
        else if e == "room_full" then "that game already has a second player"
        else e;
    let _ <- ws_send conn (NetMsg.error e message);
    IO.pure (Role.idle name)
}

def do_join_ok (r : Relay) (conn : WsConn) (name : String) (code : String) (j : Joined)
    : IO Role := do {
    let host_id : String <- IO.pure (joined_host j);
    let _ <- Ref.set r.rooms (joined_table j);
    let _ <- ws_send conn (NetMsg.welcome code "guest" "");
    let host <- relay_find r host_id;
    match host {
        Option.none => IO.pure (Role.guesting code name),
        Option.some hc => do {
            let _ <- ws_send hc (NetMsg.welcome code "guest" name);
            IO.pure (Role.guesting code name)
        }
    }
}

/// `id` is gone: tell the peer and free the seat (a host's exit ends the
/// room for both).
def do_leave (r : Relay) (id : String) (role : Role) : IO Unit :=
    match role {
        Role.idle _ => IO.pure unit,
        Role.hosting code _ => do_leave_room r id code true,
        Role.guesting code _ => do_leave_room r id code false
    }

/// Both reads of the room table in one typed pass: a `<-`-bound value stays
/// affine even when annotated (PLAN.md G3), so the table is used inside one
/// helper rather than twice in the caller.
/// The peer of `id` in `code`'s room, then the table with `id` out of it --
/// two calls over the same value, so each gets its own typed helper rather
/// than one affine binder read twice.
def leave_peer (table : RoomTable) (code : String) (id : String) : Option String :=
    room_peer table code id

def leave_table (table : RoomTable) (code : String) (id : String) : RoomTable :=
    room_leave table code id

def do_leave_room (r : Relay) (id : String) (code : String) (was_host : Bool) : IO Unit := do {
    let t0 <- Ref.get r.rooms;
    let peer <- IO.pure (leave_peer t0 code id);
    // A second read: a `<-`-bound value stays affine even with a `Copy`
    // instance (PLAN.md G3), and this table is read twice.
    let t1 <- Ref.get r.rooms;
    let after <- IO.pure (leave_table t1 code id);
    let _ <- Ref.set r.rooms after;
    match peer {
        Option.none => IO.pure unit,
        Option.some p => do {
            let target <- relay_find r p;
            match target {
                Option.none => IO.pure unit,
                Option.some conn => do {
                    let _ <- ws_send conn (if was_host then host_left else guest_left);
                    IO.pure unit
                }
            }
        }
    }
}

/// Forward an accepted message and refresh the room's clock.
def do_forward (r : Relay) (id : String) (code : String) (m : NetMsg) : IO Unit := do {
    let now <- now_ms;
    let table <- Ref.get r.rooms;
    let _ <- Ref.set r.rooms (room_touch table code now);
    send_peer r code id m
}

// ── the role machine ────────────────────────────────────────────────

/// One decoded message, against the current role. Returns the next role.
def step (r : Relay) (id : String) (conn : WsConn) (role : Role) (m : NetMsg)
    : IO Role :=
    match role {
        Role.idle name => step_idle r id conn name m,
        Role.hosting code _ => forward_step r id role code (relay_from_host m),
        Role.guesting code _ => forward_step r id role code (relay_from_guest m)
    }

/// A connection with no room: `hello`, then `create`/`join`.
def step_idle (r : Relay) (id : String) (conn : WsConn) (name : String) (m : NetMsg)
    : IO Role :=
    match m {
        NetMsg.hello version who => step_hello conn name version who,
        NetMsg.create => do_create r id conn name,
        NetMsg.join code => do_join r id conn name code,
        _ => do {
            let _ <- ws_send conn (NetMsg.error "not_ready" "say hello first");
            IO.pure (Role.idle name)
        }
    }

/// Keep the name the peer gave, unless the page is from another wire version.
def step_hello (conn : WsConn) (name : String) (version : I64) (who : String) : IO Role :=
    if Bool.not (version == coop_version)
    then do {
        let _ <- ws_send conn (NetMsg.error "bad_version" "this page is out of date; reload it");
        IO.pure (Role.idle name)
    }
    else IO.pure (Role.idle who)

def forward_step (r : Relay) (id : String) (role : Role) (code : String)
    (action : RelayAction) : IO Role :=
    match action {
        RelayAction.forward fwd => do {
            do_forward r id code fwd;
            IO.pure role
        },
        RelayAction.discard => IO.pure role,
        RelayAction.refuse c t => do {
            let target <- relay_find r id;
            match target {
                Option.none => IO.pure role,
                Option.some conn => do {
                    let _ <- ws_send conn (NetMsg.error c t);
                    IO.pure role
                }
            }
        }
    }

// ── the session ─────────────────────────────────────────────────────

/// One connection's whole life: read, step, repeat until the socket closes.
#[terminating] // each turn either reads one message or ends the loop
def session_go (r : Relay) (id : String) (conn : WsConn) (role : Role) : IO Unit := do {
    let r0 <- Ws.recv conn;
    let role0 : Role <- IO.pure role;
    match r0 {
        Result.err _ => do_leave r id role0,
        Result.ok m => session_message r id conn role0 m
    }
}

#[terminating]
def session_message (r : Relay) (id : String) (conn : WsConn) (role : Role) (m : WsMessage)
    : IO Unit :=
    let decoded : Result String NetMsg := net_decode (WsMessage.text_of m) in
    match decoded {
        Result.err e => do {
            let _ <- ws_send conn (NetMsg.error "bad_message" e);
            session_go r id conn role
        },
        Result.ok msg => session_decoded r id conn role msg
    }

#[terminating]
def session_decoded (r : Relay) (id : String) (conn : WsConn) (role : Role) (m : NetMsg)
    : IO Unit := do {
    let next <- step r id conn role m;
    session_go r id conn next
}

/// Register, run the session, unregister -- whatever ends it.
def relay_session (r : Relay) (conn : WsConn) : IO Unit := session_with r conn

/// The session's three uses of its id.
///
/// The id is passed to `session_id`, which takes it as a TYPED parameter: a
/// `<-`-bound binder has no type at a field access, so `id.raw` inside this
/// `do` block fails to elaborate. `ConnId` is `Copy`,
/// so the parameter version names its one field three times legally.
def session_with (r : Relay) (conn : WsConn) : IO Unit := do {
    let id <- ConnId.next r;
    session_id r conn id
}

def session_id (r : Relay) (conn : WsConn) (id : ConnId) : IO Unit := do {
    relay_register r (ConnId.raw_of id) conn;
    session_go r (ConnId.raw_of id) conn (Role.idle "");
    relay_unregister r (ConnId.raw_of id)
}

/// A connection id that `do`-blocks can hold without going affine: `Copy` by
/// construction, so the register/run/unregister sequence may name it three
/// times.
/// A connection id. Named `ConnId`, not `Id`: a bare `Id` collides with
/// `init::id::Id` (the same shadowing as PLAN.md G17) and the struct's own
/// field access then fails to elaborate.
pub struct ConnId {
    raw : String
}

pub instance Copy ConnId {
    def copy (x : ConnId) : Pair ConnId ConnId := Pair.pair x x
}

/// The id's text. A named getter, because a field access on a `<-`-bound
/// binder does not elaborate.
pub def ConnId.raw_of (i : ConnId) : String := i.raw

pub def ConnId.next (r : Relay) : IO ConnId := do {
    let n <- Ref.get r.next_id;
    let _ <- Ref.set r.next_id (I64.add n 1i64);
    let m <- Ref.get r.next_id;
    let id <- ConnId.make (I64.to_string (I64.sub m 1i64));
    IO.pure id
}

/// Wrap an id string. A named helper because a `let x : T := ...` statement
/// inside a `do` block does not parse.
pub def ConnId.make (raw : String) : IO ConnId :=
    IO.pure { raw := raw : ConnId }

// ── tickets and the route ──────────────────────────────────────────

/// The last path segment of `/api/ws/<ticket>` (`""` when there is none).
def ticket_of_path (path : String) : String :=
    match List.reverse (String.split path "/") {
        List.empty => "",
        List.cons last _ => last
    }

/// The relay's `HandlerT` route.
///
/// The ticket is spent here, before the upgrade: an unknown or expired one
/// answers 401 without ever opening a socket. Spending it in this handler
/// (rather than inside the session) is what makes it single-use even if the
/// upgrade itself fails.
pub def relay_handler (r : Relay) (cfg : WsConfig) : HandlerT IO Response :=
    HandlerT.mk (fn (ctx : Ctx) => relay_admit r cfg ctx)

def relay_admit (r : Relay) (cfg : WsConfig) (ctx : Ctx) : IO (Result HttpError Response) := do {
    let ticket : String <- IO.pure (ticket_of_path (Ctx.path ctx));
    let now <- now_ms;
    let table <- Ref.get r.tickets;
    match ticket_consume table ticket now {
        Result.err _ => admit_refused,
        Result.ok c => admit_accepted r cfg c ctx
    }
}

def admit_refused : IO (Result HttpError Response) :=
    IO.pure (Result.ok (Response.text 401u16 "invalid or expired ticket"))

def admit_accepted (r : Relay) (cfg : WsConfig) (c : Consumed) (ctx : Ctx)
    : IO (Result HttpError Response) := do {
    let _ <- Ref.set r.tickets (consumed_table c);
    let subject <- IO.pure (consumed_subject c);
    HandlerT.run (handler_with r cfg subject) ctx
}

/// The upgrade handler, after the ticket has been accepted. `subject` is the
/// identity the ticket was minted for; the room table keys on the connection
/// id today, so it is unused -- and deliberately still a parameter, because it
/// is the seam where a per-identity rule (one room per player, a ban list)
/// would go without changing this file's shape.
def handler_with (r : Relay) (cfg : WsConfig) (_subject : String) : HandlerT IO Response :=
    MoonWs.handler cfg [coop_protocol] (fn (_ctx : Ctx) (conn : WsConn) => relay_session r conn)

/// How many tickets are outstanding (diagnostics).
def tickets_out (r : Relay) : IO I64 := do {
    let t <- Ref.get r.tickets;
    IO.pure (tickets_count t)
}
