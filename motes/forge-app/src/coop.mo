// Co-op on the client side: the decisions a page makes about its socket,
// kept native and testable.
//
// The wire itself is `forge_online::net` (pure, tested). What lives here is
// everything about *being a page in a session*: which URL to open, when to
// send, what an incoming frame does to the model, and when the peer has gone
// quiet. `forge_app::web` keeps only the oak glue.
//
// ## Roles
//
//   role_host   -- steps the game, sends `state`, receives `intent`
//   role_guest  -- sends `intent`, applies `state`
//
// Nothing here trusts the peer: `apply_state` is the only function that takes
// a remote number into the model, and the wire has already clamped it.

use std::derive {derive_copy, derive_clone}
use init::copy {Copy}
use forge_core::ecs {World}
use lib::input {Input}
use forge_online::{
    NetMsg, WireState, WireIntent, wire_neutral, net_encode, net_decode, coop_protocol,
    role_host, role_guest, normalize_code, code_valid, intent_mx, intent_mz,
    intent_jump_pressed, intent_jump_held, intent_dash_pressed, intent_sprint,
    intent_ability_pressed, intent_swap_pressed, state_level, state_sparks, state_total,
    state_falls, state_seconds, state_player, state_companion, state_won,
    hero_x, hero_y, hero_z, hero_yaw, hero_grounded, wire_intent
}

// ── Roles ───────────────────────────────────────────────────────────

/// What this page is, as far as co-op goes. `Copy`.
#[derive Copy Clone]
pub type CoopRole {
    /// Not in a session.
    solo,
    /// Stepping the game for both players.
    host (code : String) (peer : String),
    /// Sending intent, drawing the host's state.
    guest (code : String) (peer : String)
}

pub def is_solo (r : CoopRole) : Bool :=
    match r {
        CoopRole.solo => true,
        _ => false
    }

pub def is_host (r : CoopRole) : Bool :=
    match r {
        CoopRole.host _ _ => true,
        _ => false
    }

pub def is_guest (r : CoopRole) : Bool :=
    match r {
        CoopRole.guest _ _ => true,
        _ => false
    }

pub def role_code (r : CoopRole) : String :=
    match r {
        CoopRole.solo => "",
        CoopRole.host code _ => code,
        CoopRole.guest code _ => code
    }

pub def role_peer (r : CoopRole) : String :=
    match r {
        CoopRole.solo => "",
        CoopRole.host _ peer => peer,
        CoopRole.guest _ peer => peer
    }

// ── The URL ─────────────────────────────────────────────────────────
//
// A browser cannot set a header on `WebSocket`, so the ticket rides in the
// path. The page asks the broker for a ticket (`/api/ws-ticket`) and turns
// the `path` it answers with into an absolute `ws://` URL.

/// Replace a leading `http` in `origin` with `ws`, so an `https` page gets
/// `wss` (one letter of difference; the scheme is kept otherwise intact).
pub def ws_origin (origin : String) : String :=
    if String.starts_with "https://" origin then String.concat "wss://" (String.drop 8 origin)
    else if String.starts_with "http://" origin then String.concat "ws://" (String.drop 7 origin)
    else if String.starts_with "wss://" origin then origin
    else if String.starts_with "ws://" origin then origin
    else String.concat "ws://" origin

/// The socket URL for `path` (as answered by `/api/ws-ticket`) on `origin`.
pub def socket_url (origin : String) (path : String) : String :=
    String.concat (ws_origin origin) path

// ── Rate ────────────────────────────────────────────────────────────
//
// The host ships state at 15 Hz and the guest ships intent at 20 Hz: both are
// COUNTS of frames, not clocks. A counter needs no clock, cannot drift with a
// page throttled to 1 fps, and cannot be fooled into sending twice in one
// frame.

/// How many frames between two `state` sends (60 fps -> 15 Hz).
pub def state_every : I64 := 4

/// How many frames between two `intent` sends (60 fps -> 20 Hz).
pub def intent_every : I64 := 3

/// Has a counter waited a whole `state` interval? (`since_send` counts frames
/// SINCE the last send, so this is `>=` and `sent` resets it to 0. A modulo
/// made 0 itself a send frame -- and 0 is what `sent` writes -- so the frame
/// right after every send sent again, at double rate.)
pub def state_ready (since_send : I64) : Bool :=
    since_send >= state_every

/// Has a counter waited a whole `intent` interval?
pub def intent_ready (since_send : I64) : Bool :=
    since_send >= intent_every

// ── The session model ───────────────────────────────────────────────

/// Everything co-op about one page. `Copy` (no lists, no handles).
#[derive Copy Clone]
pub struct Coop {
    role : CoopRole,
    /// The socket URL, once a ticket has been minted.
    url : String,
    /// The code the player typed to join (`""` until they do).
    pending_code : String,
    /// The last state the host sent us (a guest's whole view of the run).
    state : Option WireState,
    /// The last intent the guest sent us (a host's input for hero 2).
    guest_intent : Option WireIntent,
    /// Frames since this page last sent a `state` (host) or `intent` (guest);
    /// a send is due when it reaches that role's interval.
    since_send : I64,
    /// Frames since the host last heard from the guest: a guest that has gone
    /// quiet for `peer_quiet` frames is shown as disconnected, but the room is
    /// not torn down (a browser tab that was backgrounded comes back).
    since_peer : I64,
    /// The last thing the relay told us to show the player.
    notice : String
}

/// A fresh session. `since_send` starts at the longer interval so a role that
/// is adopted on this frame sends at once (`state_due`/`intent_due` both
/// compare `>=` against their own interval).
pub def coop_new : Coop :=
    { role := CoopRole.solo, url := "", pending_code := "", state := Option.none,
      guest_intent := Option.none, since_send := state_every, since_peer := 0,
      notice := "" : Coop }

/// The host is `peer_quiet` frames behind before the page stops waiting for a
/// guest's input (1 s at 60 fps).
pub def peer_quiet : I64 := 60

pub def coop_role (c : Coop) : CoopRole := c.role

pub def coop_url (c : Coop) : String := c.url

pub def coop_notice (c : Coop) : String := c.notice

pub def coop_state (c : Coop) : Option WireState := c.state

pub def coop_guest_intent (c : Coop) : Option WireIntent := c.guest_intent

pub def coop_pending_code (c : Coop) : String := c.pending_code

/// Has the guest gone quiet for too long? (Only meaningful for a host.)
pub def peer_gone (c : Coop) : Bool :=
    is_host c.role && c.since_peer > peer_quiet

/// The code to display to the player, if any.
pub def display_code (c : Coop) : String :=
    match c.role {
        CoopRole.solo => "",
        CoopRole.host code _ => code,
        CoopRole.guest code _ => code
    }

// ── Transitions ─────────────────────────────────────────────────────

/// The player typed a join code: remember it (validated on submit).
pub def with_code (c : Coop) (typed : String) : Coop :=
    { c with pending_code := typed }

/// A ticket came back: the page is now ready to open `url`.
pub def with_url (c : Coop) (url : String) : Coop :=
    { c with url := url, notice := "" }

/// Opening a socket failed, or the relay refused: show it and stop claiming a
/// session (a wrong code must not leave the page half-hosted).
pub def with_notice (c : Coop) (notice : String) : Coop :=
    { c with notice := notice }

pub def failed (c : Coop) (notice : String) : Coop :=
    { coop_new with notice := notice }

/// The socket is open: say hello, which is what the relay requires first.
pub def hello (c : Coop) (name : String) : String :=
    net_encode (NetMsg.hello 1i64 name)

/// The player wants to host: `create` once the socket is open.
pub def create_msg : String := net_encode NetMsg.create

/// The player wants to join: `join` with the typed code, or `""` when the
/// code is not well-formed (the caller then shows `bad_code_notice` instead of
/// sending).
pub def join_msg (c : Coop) : Option String :=
    if code_valid c.pending_code
    then Option.some (net_encode (NetMsg.join (normalize_code c.pending_code)))
    else Option.none

pub def bad_code_notice : String := "that code is not a room code (four letters or digits)"

/// The relay answered `welcome`.
///
/// A connection keeps the role it was given and never switches: the relay
/// sends a host a SECOND `welcome` (role `guest`) when someone joins its room,
/// purely so the host can show who is there. Adopting that role would turn the
/// host into a guest that sends intents and draws nothing, so an already-set
/// role only takes the peer's name.
pub def welcomed (c : Coop) (code : String) (role : String) (peer : String) : Coop :=
    if Bool.not (role == role_host || role == role_guest)
    then with_notice c "the relay sent an unknown role"
    else if is_host c.role
    then { c with role := CoopRole.host code peer, notice := "" }
    else if is_guest c.role
    then { c with role := CoopRole.guest code peer, notice := "" }
    else if role == role_host
    then { c with role := CoopRole.host code peer, notice := "" }
    else { c with role := CoopRole.guest code peer, notice := "" }

/// Leave deliberately: the same "back to solo" as a peer leaving, but with a
/// notice the player caused.
pub def end_session (c : Coop) : Coop :=
    { coop_new with notice := "you left the game" }

/// `s` as the text a `state` frame carries (the page builds it from the world
/// it just stepped; the game mote owns the world-reading half).
pub def encode_state (s : WireState) : String := net_encode (NetMsg.state s)

/// The subprotocol a socket asks for.
pub def coop_protocol_name : String := coop_protocol

/// The session ended (either side, or the socket): back to solo, with the
/// reason showing.
pub def ended (c : Coop) (reason : String) : Coop :=
    { coop_new with notice := reason }

// ── Incoming frames ─────────────────────────────────────────────────

/// One frame from the socket, folded into the model.
pub def received (c : Coop) (text : String) : Coop :=
    match net_decode text {
        Result.err e => with_notice c e,
        Result.ok m => received_msg c m
    }

pub def received_msg (c : Coop) (m : NetMsg) : Coop :=
    match m {
        NetMsg.welcome code role peer => welcomed c code role peer,
        NetMsg.left reason => ended c reason,
        NetMsg.error _ message => with_notice c message,
        NetMsg.state s => heard_state c s,
        NetMsg.intent i => heard_intent c i,
        _ => c
    }

/// A state frame: adopt it and restart the quiet timer.
pub def heard_state (c : Coop) (s : WireState) : Coop :=
    { c with state := Option.some s, since_peer := 0, notice := "" }

/// An intent frame from the guest.
pub def heard_intent (c : Coop) (i : WireIntent) : Coop :=
    { c with guest_intent := Option.some i, since_peer := 0, notice := "" }

/// A frame elapsed with nothing from the peer (a host watching for a quiet
/// guest). A guest's `since_peer` is not used: `state` frames carry it.
pub def tick (c : Coop) : Coop :=
    { c with since_peer := I64.add c.since_peer 1, since_send := I64.add c.since_send 1 }

/// Should this page send a `state` on this frame, and is it a host?
pub def state_due (c : Coop) : Bool :=
    is_host c.role && state_ready c.since_send

/// Should this page send an `intent` on this frame, and is it a guest?
pub def intent_due (c : Coop) : Bool :=
    is_guest c.role && intent_ready c.since_send

/// The frame just sent something, so the counter restarts.
pub def sent (c : Coop) : Coop :=
    { c with since_send := 0 }

// ── What the other side needs ───────────────────────────────────────

/// The guest's hero pose, as the host draws it. A host whose guest has gone
/// quiet sends a neutral pose so the second hero stops where it is instead of
/// sliding on the last input forever.
pub def guest_ready (c : Coop) : Bool :=
    match c.guest_intent {
        Option.none => false,
        Option.some _ => true
    }

// ── The local input as an intent ────────────────────────────────────
//
// A guest sends what its own player does. The page's `Input` (keys held, the
// touch stick) is already the game's run direction, so this is a mapping, not
// a simulation: `forge_app::web` reads the input and this turns it into the
// wire's frame.

/// One frame of input, as the wire's intent.
pub def intent_of_input (mx : F64) (mz : F64) (jump_pressed : Bool) (jump_held : Bool)
    (dash_pressed : Bool) (sprint : Bool) (ability_pressed : Bool) (swap_pressed : Bool)
    : WireIntent :=
    wire_intent mx mz jump_pressed jump_held dash_pressed sprint ability_pressed swap_pressed

// ── What only the game knows ────────────────────────────────────────
//
// `forge-app` owns the socket, the roles and the rates, but it cannot read a
// game's components: a `state` frame is whatever that game decides is visible,
// and a guest's hero is that game's own Intent. So the game supplies five
// functions and `forge_app::web` calls them. Every one is pure and native, so
// the co-op logic stays testable and the web side stays glue.

/// The game's half of a co-op session. `Copy` by identity: the page model
/// holds one and reads it on every frame.
pub struct CoopHooks {
    /// The run's visible state, as the text a `state` frame carries.
    state_text : World -> String,
    /// Fold a `state` frame's text into the guest's world.
    apply_state_text : World -> String -> World,
    /// Write the guest's intent into the host's world.
    set_guest_intent : World -> WireIntent -> World,
    /// Forget the guest: the companion goes back to the follow AI.
    clear_guest : World -> World,
    /// This page's own input, as the intent a guest sends.
    intent_of_input : World -> Input -> WireIntent
}

pub instance Copy CoopHooks {
    def copy (h : CoopHooks) : Pair CoopHooks CoopHooks := Pair.pair h h
}

pub def coop_hooks
    (state_text : World -> String)
    (apply_state_text : World -> String -> World)
    (set_guest_intent : World -> WireIntent -> World)
    (clear_guest : World -> World)
    (intent_of_input : World -> Input -> WireIntent) : CoopHooks :=
    { state_text := state_text, apply_state_text := apply_state_text,
      set_guest_intent := set_guest_intent, clear_guest := clear_guest,
      intent_of_input := intent_of_input : CoopHooks }

/// No game hooks: a page that hosts nothing and is never a guest. The demo bin
/// mounts with these.
pub def coop_hooks_none : CoopHooks :=
    coop_hooks
        (fn (_w : World) => "")
        (fn (w : World) (_t : String) => w)
        (fn (w : World) (_i : WireIntent) => w)
        (fn (w : World) => w)
        (fn (_w : World) (_i : Input) => wire_neutral)

pub def coop_state_text_of (h : CoopHooks) (w : World) : String := h.state_text w

pub def coop_apply_state_text (h : CoopHooks) (w : World) (text : String) : World :=
    h.apply_state_text w text

pub def coop_set_guest_intent (h : CoopHooks) (w : World) (i : WireIntent) : World :=
    h.set_guest_intent w i

pub def coop_clear_guest (h : CoopHooks) (w : World) : World := h.clear_guest w

pub def coop_intent_of_input (h : CoopHooks) (w : World) (i : Input) : WireIntent :=
    h.intent_of_input w i

// ── Reading a state for the HUD ─────────────────────────────────────

/// A one-line description of the host's run, for the guest's HUD.
pub def state_line (c : Coop) : String :=
    match c.state {
        Option.none => "waiting for the host",
        Option.some s => state_line_of s
    }

/// The one-line summary of a host's state.
pub def state_line_of (s : WireState) : String :=
    String.concat (String.concat "level " (I64.to_string (I64.add (state_level s) 1)))
        (String.concat "  sparks " (String.concat (I64.to_string (state_sparks s))
            (String.concat "/" (I64.to_string (state_total s)))))
