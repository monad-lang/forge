// forge-app on the web: the browser host, as an OAK program.
//
// This module is web-only (it reaches `web_wasm`, `oak`, `oak_wasm` and
// forge-webgl) and is NOT re-exported from `lib.mo`, so the native test
// binary never links browser externs. A web game uses exactly two modules:
// `forge_app` (build the `App`) and `forge_app::web` (run it). Its bin
// holds the three thunks the web loader calls:
//
//     #[export "c"]
//     def oak_mount : IO Unit := web_mount my_app my_rig
//
//     #[export "c"]
//     def oak_dispatch_event (handler : I64) : IO Unit := web_dispatch handler
//
//     #[export "c"]
//     def oak_tick : IO Unit := web_tick
//
//     def main : IO Unit := IO.pure unit
//
// `oak_tick` takes no app: the mounted model is in oak's state, and passing
// the app would rebuild it (and its level) on every frame (Monad is strict).
//
// Oak owns the page: the view renders the canvas (`#forge`, kept at a stable
// position so its GL context survives), the HUD panels and -- on a touch
// screen -- the on-screen controls, all as `Oak.Node`s. Input arrives as
// messages (window key subscriptions, canvas pointer/wheel handlers, touch
// buttons) and is folded into forge `Input`. Frames arrive on the
// animation-frame subscription; `update` answers each with a
// `Command.after_render` effect that fits the canvas, steps the app and
// submits the plan, so the drawing happens after the patch.
//
// The state between messages is the model (oak keeps it; forge no longer
// uses `Keep`, whose slot oak_wasm owns).
//
// One effect-driven frame:
//   resize the drawing buffer -> the rig's camera for the new aspect ->
//   `app_frame_viewed` -> `app_plan` -> `webgl_submit`.
// A click picks: the cursor's offset in the canvas -> `camera_screen_ray`
// -> `pick_entity` against the last stepped world (what is on screen).

use std::derive {}
use init::copy {Copy}
use web_wasm::types {Node}
use web_wasm::dom {Dom.query}
use web_wasm::window {Window.origin}
use web_wasm::fetch {Fetch.begin, Fetch.poll, Fetch.status, Fetch.read}
use web_wasm::types {WebSocket, RequestId}
use web_wasm::websocket {WebSocket.connect, WebSocket.next, WebSocket.send}
use web_wasm::media {Media.matches}
use web_wasm::console {Console.log}
use oak {WebEvent, ListenerFlags, HandlerResult, Subscription}
use oak::typed {Oak.Node}
use oak::elements {
    Html.attr, Html.button, Html.canvas, Html.class_, Html.div, Html.id_, Html.input, Html.kbd,
    Html.placeholder, Html.span, Html.style, Html.style_attr, Html.text, Html.type_, Html.value_
}
use oak::events {
    Html.on, Html.on_click, Html.on_click_with, Html.on_input, Html.on_pointerdown,
    Html.on_pointerup, Html.on_pointermove, Html.on_pointerleave, Html.on_pointercancel,
    Html.on_submit_prevent, Html.on_wheel
}
use oak::app {Command, Host, Program}
use oak_wasm::program {Runtime.mount, Runtime.dispatch, Runtime.tick}
use oak_ui::theme {Ui.Theme}
use oak_ui::css {Ui.stylesheet_auto}
use oak_ui::layout {Ui.row}
use forge_core::ecs {World, Entity, entity_id, empty_world}
use forge_math {v3_zero}
use forge_render {Camera, FramePlan, Picked, camera_screen_ray, pick_entity}
use forge_render {Assets}
use forge_online::api {path_ws_ticket}
use forge_online::net {NetMsg, WireIntent, net_encode, wire_neutral, wire_intent, coop_protocol, role_host, role_guest}
use web_event::websocket {WsEvent, WsData, WsData.text_of}
use json::json {Json, Json.parse, Json.get_object, Json.object_get, Json.get_str}
use forge_webgl {
    WebGlRenderer, webgl_attach, webgl_submit, webgl_resize, webgl_client_size, Size2,
    size_width, size_height
}
use lib::app {
    App, CameraRig, Frame, frame_world, app_initial_world, app_assets, app_frame_viewed, app_plan,
    app_new, camera_rig, rig_camera
}
use lib::orbit {world_camera_rig}
use lib::hud {Hud, world_hud, hud_lookup}
use lib::stick {stick_radius, stick_dirs, knob_of}
use lib::pick {world_pick}
use lib::coop {
    CoopRole, Coop, coop_new, coop_role, coop_url, coop_notice, coop_state, coop_guest_intent,
    is_solo, is_host, is_guest, display_code, peer_gone, tick, state_due, intent_due, sent,
    received, with_code, with_url, with_notice, failed, hello, create_msg, join_msg,
    bad_code_notice, end_session, coop_protocol_name, socket_url, state_line,
    CoopHooks, coop_hooks_none, coop_state_text_of, coop_apply_state_text,
    coop_set_guest_intent, coop_clear_guest, coop_intent_of_input
}
use lib::input {
    Input, InputEvent, input_empty, input_apply, input_end_frame,
    input_key_down, input_key_up, input_pointer_move, input_pointer_down, input_pointer_up,
    input_pointer_leave, input_wheel, input_focus_lost, input_wheel_pixels
}

// `RequestId` names an entry in the browser's fetch table. A poll reads it
// once per frame, and the model holds it across the frames in between, so
// sharing the id is a bit copy. `web_wasm` does not declare this instance at
// the pin.
pub instance Copy RequestId {
    def copy (r : RequestId) : Pair RequestId RequestId := Pair.pair r r
}

// ── Model ───────────────────────────────────────────────────────────

/// Everything the page keeps between messages. `Copy` by identity (it holds
/// persistent values and GL handles; a duplicate shares).
pub struct WebModel {
    app : App,
    rig : CameraRig,
    world : World,
    input : Input,
    last_ms : F64,
    renderer : Option WebGlRenderer,
    status : String,
    picked : I64,
    vw : F64,
    vh : F64,
    touch : Bool,
    setting_up : Bool,
    knob_x : F64,
    knob_y : F64,
    held : List String,
    /// The pointer that owns the touch stick; -1 when none.
    stick_id : I64,
    /// The combined oak_ui + forge stylesheet, built once at mount.
    css : String,
    /// Co-op: this page's role and what the peer sent. Solo by default, so a
    /// page that never opens the panel behaves exactly as before.
    coop : Coop,
    /// What only the game can answer (its state frame, its own intent).
    hooks : CoopHooks,
    /// The in-flight ticket request. A browser `fetch` resolves between
    /// frames, so this is a state machine across ticks -- polling it inside
    /// one effect spins and exhausts the wasm heap.
    ticket_req : Option RequestId,
    /// The live socket, once one is open. Held here rather than driven by
    /// `Subscription.websocket`: oak applies subscriptions only at MOUNT, so a
    /// socket a player asks for later has to be opened here and drained per
    /// frame.
    socket : Option WebSocket,
    /// Did the player ask to HOST? Both intents open the same socket, and the
    /// relay needs `create` for one and `join <code>` for the other, so the
    /// choice has to survive the ticket round trip.
    wants_host : Bool
}

pub instance Copy WebModel {
    def copy (m : WebModel) : Pair WebModel WebModel := Pair.pair m m
}

def model_new_with (a : App) (rig : CameraRig) (css : String) (hooks : CoopHooks) : WebModel :=
    { app := a, rig := rig, world := app_initial_world a, input := input_empty,
      last_ms := 0.0 - 1.0, renderer := Option.none, status := "", picked := 0 - 1,
      vw := 1.0, vh := 1.0, touch := false, setting_up := false, knob_x := 0.0, knob_y := 0.0,
      held := List.empty, stick_id := 0 - 1, css := css, coop := coop_new,
      hooks := hooks, ticket_req := Option.none, socket := Option.none,
      wants_host := false : WebModel }

/// The mounted model. The stylesheet is static (two fixed themes), so it is
/// built here, once, rather than in `view` on every render.
def model_new (a : App) (rig : CameraRig) (hooks : CoopHooks) : WebModel :=
    model_new_with a rig
        (String.concat (Ui.stylesheet_auto Ui.Theme.light Ui.Theme.dark) forge_css) hooks

/// The tick's program needs an init value it never uses (the mounted model
/// is in oak's state; `Runtime.tick` reads only update/view/subscriptions).
/// Keep it cheap: no app or level construction.
def model_blank : WebModel :=
    model_new_with app_new (camera_rig v3_zero v3_zero 1.0) "" coop_hooks_none

// ── Messages ────────────────────────────────────────────────────────

/// What the page sends itself.
pub type WebMsg {
    frame (t : F64),
    ready (r : WebGlRenderer) (touch : Bool),
    failed (e : String),
    stepped (world : World) (vw : F64) (vh : F64),
    key (code : String) (down : Bool),
    pointer (kind : String) (x : F64) (y : F64) (button : I64),
    wheel (dy : F64) (mode : I64),
    /// The touch stick: a press (which takes ownership, by pointer id), a
    /// move from the owning pointer, and its release.
    stick_start (id : I64) (x : F64) (y : F64),
    stick (id : I64) (x : F64) (y : F64),
    stick_release (id : I64),
    touch_key (code : String) (down : Bool),
    release,
    click (x : F64) (y : F64),
    window_blur,
    /// The socket delivered `text` (a `WsEvent` already unwrapped).
    net (text : String),
    /// The socket opened: say hello.
    net_open,
    /// The socket closed or failed, with the reason to show.
    net_closed (reason : String),
    /// The ticket request began (the id the fetch is polled by).
    ticket_started (req : RequestId),
    /// The socket object is ready to store (from the effect).
    socket_opened (w : WebSocket),
    /// The ticket came back: `url` is the socket URL, `""` for a refusal.
    coop_ticket (url : String),
    /// The ticket request is still pending: poll it again next frame.
    poll_again,
    /// The player wants to host.
    coop_host,
    /// The player typed in the join field.
    coop_code (code : String),
    /// The player submitted the code they typed.
    coop_join,
    /// The player left deliberately.
    coop_leave,
    noop
}

// ── Effects ─────────────────────────────────────────────────────────

/// What the page asks the host to do. Everything IO lives here; `update`
/// and `view` stay pure.
pub type WebFx {
    setup (app : App),
    step (r : WebGlRenderer) (app : App) (rig : CameraRig) (world : World) (input : Input) (dt : F64),
    /// Ask the broker for a single-use socket ticket (`/api/ws-ticket`).
    ticket,
    /// Open the co-op socket at `url`.
    open_socket (url : String),
    /// Send `text` on `w`. A send has nothing to report: a failure shows up as
    /// the socket's own close on the next drain.
    send_text (w : WebSocket) (text : String),
    /// Take one queued frame off `w`.
    pump (w : WebSocket),
    /// One poll of the ticket request `r`.
    poll_ticket (r : RequestId)
}

// ── Touch stick ─────────────────────────────────────────────────────

/// The stick's direction math lives in the native `lib::stick` module (with
/// its own tests); this file keeps the model update and the event glue.

// ── Event helpers ──
//
// A lambda parameter is affine, so a handler that reads two fields of the
// event cannot be a `fn (e : WebEvent) =>` inline: these named defs take the
// event last and are partially applied in the view.

def pointer_msg (kind : String) ({ offset_x, offset_y, button, .. } : WebEvent) : WebMsg :=
    WebMsg.pointer kind offset_x offset_y button

def click_msg ({ offset_x, offset_y, .. } : WebEvent) : WebMsg := WebMsg.click offset_x offset_y

def wheel_msg ({ delta_y, delta_mode, .. } : WebEvent) : WebMsg := WebMsg.wheel delta_y delta_mode

def stick_start_msg ({ offset_x, offset_y, pointer_id, .. } : WebEvent) : WebMsg :=
    WebMsg.stick_start pointer_id offset_x offset_y

def stick_move_msg ({ offset_x, offset_y, pointer_id, .. } : WebEvent) : WebMsg :=
    WebMsg.stick pointer_id offset_x offset_y

def stick_release_msg ({ pointer_id, .. } : WebEvent) : WebMsg :=
    WebMsg.stick_release pointer_id

/// `Html.on_pointerleave`/`on_pointercancel` take a CONSTANT message, so they
/// cannot see the pointer id; this is the generic-attribute form instead.
def stick_release_hr (e : WebEvent) : HandlerResult WebMsg :=
    HandlerResult.msg (stick_release_msg e)

def key_msg (down : Bool) ({ code, .. } : WebEvent) : WebMsg := WebMsg.key code down

def frame_msg ({ time_stamp, .. } : WebEvent) : WebMsg := WebMsg.frame time_stamp

// ── Update ──────────────────────────────────────────────────────────

def dt_between (last_ms : F64) (now_ms : F64) : F64 :=
    if last_ms < 0.0 then 0.0
    else
        let dt : F64 := (now_ms - last_ms) / 1000.0 in
        if dt < 0.0 then 0.0 else if dt > 0.25 then 0.25 else dt

def held_has (es : List String) (s : String) : Bool :=
    match es {
        List.empty => false,
        List.cons h t => if h == s then true else held_has t s
    }

#[terminating]
def held_add (es : List String) (s : String) : List String :=
    match es {
        List.empty => List.cons s List.empty,
        List.cons h t => if h == s then List.cons h t else List.cons h (held_add t s)
    }

#[terminating]
def held_del (es : List String) (s : String) : List String :=
    match es {
        List.empty => List.empty,
        List.cons h t => if h == s then held_del t s else List.cons h (held_del t s)
    }

def with_input (m : WebModel) (ev : InputEvent) : WebModel :=
    { m with input := input_apply m.input ev }

/// A key going down or up (keyboard or an on-screen button).
def key_model (m : WebModel) (code : String) (down : Bool) : WebModel :=
    let ev : InputEvent := (if down then input_key_down code else input_key_up code) in
    with_input m ev

/// A touch-pad button: the key goes down while it is held, up on release.
def touch_model (m : WebModel) (code : String) (down : Bool) : WebModel :=
    let m1 : WebModel := key_model m code down in
    if down then { m1 with held := held_add m1.held code }
    else { m1 with held := held_del m1.held code }

/// Set the four direction keys to exactly `dirs` (touch or release).
def apply_dirs (m : WebModel) (dirs : List Bool) : WebModel :=
    let codes : List String := ["KeyW", "KeyS", "KeyA", "KeyD"] in
    apply_dirs_go m codes dirs

#[terminating]
def apply_dirs_go (m : WebModel) (codes : List String) (dirs : List Bool) : WebModel :=
    match codes {
        List.empty => m,
        List.cons c rest =>
            match dirs {
                List.empty => apply_dirs_go m rest List.empty,
                List.cons want more =>
                    let has : Bool := held_has m.held c in
                    let m1 : WebModel := (if want == has then m else touch_model m c want) in
                    apply_dirs_go m1 rest more
            }
    }

def stick_model (m : WebModel) (x : F64) (y : F64) : WebModel :=
    let cx : F64 := x - stick_radius in
    let cy : F64 := y - stick_radius in
    let p : Pair F64 F64 := knob_of cx cy in
    match p {
        Pair.pair kx ky =>
            let m1 : WebModel := apply_dirs m (stick_dirs cx cy) in
            { m1 with knob_x := kx, knob_y := ky }
    }

/// A press takes ownership: the stick follows only this pointer id from now
/// on (a second finger or a mouse hover must not steer).
def stick_start_model (m : WebModel) (id : I64) (x : F64) (y : F64) : WebModel :=
    stick_model ({ m with stick_id := id }) x y

def stick_move_model (m : WebModel) (id : I64) (x : F64) (y : F64) : WebModel :=
    if id == m.stick_id then stick_model m x y else m

def stick_release_model (m : WebModel) : WebModel :=
    let m1 : WebModel := apply_dirs m [false, false, false, false] in
    { m1 with knob_x := 0.0, knob_y := 0.0 }

/// Release only the pointer that owns the stick (another finger's up is a
/// no-op).
def stick_release_for (m : WebModel) (id : I64) : WebModel :=
    if id == m.stick_id then
        let m1 : WebModel := stick_release_model m in
        { m1 with stick_id := 0 - 1 }
    else m

/// Release the stick regardless of which pointer owns it (blur, teardown).
def stick_clear (m : WebModel) : WebModel :=
    let m1 : WebModel := stick_release_model m in
    { m1 with stick_id := 0 - 1 }

/// Every held on-screen key released (window blur).
#[terminating]
def release_all (m : WebModel) (held : List String) : WebModel :=
    match held {
        List.empty => stick_clear m,
        List.cons c rest => release_all (touch_model m c false) rest
    }

def pointer_model (m : WebModel) (kind : String) (x : F64) (y : F64) (button : I64) : WebModel :=
    let ev : InputEvent :=
        (if kind == "down" then input_pointer_down button x y
        else if kind == "up" then input_pointer_up button x y
        else if kind == "leave" then input_pointer_leave
        else input_pointer_move x y) in
    with_input m ev

/// A click: the entity id under canvas point `(x, y)` (the nearest
/// collider when the world has colliders, else the nearest mesh), or -1.
def click_model (m : WebModel) (x : F64) (y : F64) : WebModel :=
    let cam : Camera := view_of m.rig m.world m.vw m.vh in
    let id : I64 :=
        (match camera_screen_ray cam m.vw m.vh x y {
            Option.none => 0 - 1,
            Option.some r => world_pick m.world (app_assets m.app) r
        }) in
    { m with picked := id }

// ── Co-op ───────────────────────────────────────────────────────────
//
// Every decision (roles, rates, what a frame means) is in `lib::coop`, native
// and tested, and everything about the game is in the game (via `CoopHooks`).
// What is here is only what needs a socket or the page:
//
//   * `coop_host` asks the broker for a ticket, and the ticket's answer opens
//     the socket (a browser fetch resolves between frames, so the request is
//     polled from `on_frame`, never inside one effect);
//   * the socket is opened imperatively and drained one frame per tick,
//     because oak applies subscriptions only at mount;
//   * `stepped_pair` turns "should I send this frame" into a send of the world
//     the step just produced.

def with_renderer (m : WebModel) (r : WebGlRenderer) (touch : Bool) : WebModel :=
    { m with renderer := Option.some r, touch := touch, status := "ok" }

def with_status (m : WebModel) (e : String) : WebModel :=
    { m with status := e }

def with_ticket (m : WebModel) (req : RequestId) : WebModel :=
    { m with ticket_req := Option.some req }

def with_socket (m : WebModel) (w : WebSocket) : WebModel :=
    { m with socket := Option.some w }

/// A model change with nothing to do.
def settled (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    Pair.pair m Command.none

/// A frame just stepped.
///
/// The co-op world changes are applied HERE, after the step, not in
/// `coop_net`: a socket frame and a step's result land in the same batch, and
/// the step's world was captured before the frame arrived, so writing the
/// guest's intent in `coop_net` would be overwritten by the step a moment
/// later. Applying it to the world the step just produced makes the intent
/// survive to drive the NEXT step.
///
/// `input_end_frame` runs first, so a press is reported exactly once.
def stepped_pair (m : WebModel) (world : World) (vw : F64) (vh : F64)
    : Pair WebModel (Command WebFx WebMsg) :=
    let m1 : WebModel :=
        { m with world := world, vw := vw, vh := vh, input := input_end_frame m.input } in
    let m2 : WebModel := { m1 with world := coop_world m1 m1.world } in
    coop_send m2

/// Fold this page's co-op state into the world: a host writes the guest's
/// intent (which displaces the companion's follow AI), a guest copies the
/// host's heroes, and a page with no session drops any intent a previous one
/// left behind.
def coop_world (m : WebModel) (world : World) : World :=
    if is_host (coop_role m.coop)
    then
        match coop_guest_intent m.coop {
            Option.some i => coop_set_guest_intent m.hooks world i,
            Option.none => coop_clear_guest m.hooks world
        }
    else if is_guest (coop_role m.coop)
    then coop_apply_state_text m.hooks world (guest_frame_text m.coop)
    else coop_clear_guest m.hooks world

/// The guest's last state frame as text, so it can be re-applied (the guest's
/// own simulation runs every frame; the host's pose must win).
def guest_frame_text (c : Coop) : String :=
    match coop_state c {
        Option.none => "",
        Option.some s => net_encode (NetMsg.state s)
    }

/// Age the session by one frame and send what this page owes the peer.
def coop_send (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    let aged : WebModel := { m with coop := tick m.coop } in
    if is_solo (coop_role aged.coop)
    then settled aged
    else if state_due aged.coop
    then
        let text : String := coop_state_text_of aged.hooks aged.world in
        let sent_m : WebModel := { aged with coop := sent aged.coop } in
        Pair.pair sent_m (send_cmd sent_m.socket text)
    else if intent_due aged.coop
    then
        let text : String := net_encode (NetMsg.intent (coop_intent_of_input aged.hooks aged.world aged.input)) in
        let sent_m : WebModel := { aged with coop := sent aged.coop } in
        Pair.pair sent_m (send_cmd sent_m.socket text)
    else settled aged

/// Send `text` on `socket`, or nothing when there is no socket (a session that
/// has ended must not keep writing).
def send_cmd (socket : Option WebSocket) (text : String) : Command WebFx WebMsg :=
    match socket {
        Option.none => Command.none,
        Option.some w => Command.perform (WebFx.send_text w text)
    }

/// Is a session already under way (or starting)? A second click on Host or
/// Join must not open a second socket: the relay would seat it as a second
/// connection and the first would keep sending into a room it left. (The
/// branches are spelled out because a `match` in an `else` needs parens.)
def coop_busy (m : WebModel) : Bool :=
    if Bool.not (is_solo (coop_role m.coop))
    then true
    else if has_socket m.socket
    then true
    else if has_ticket m.ticket_req
    then true
    else Bool.not (String.is_empty (coop_url m.coop))

def has_socket (s : Option WebSocket) : Bool :=
    match s {
        Option.none => false,
        Option.some _ => true
    }

def has_ticket (r : Option RequestId) : Bool :=
    match r {
        Option.none => false,
        Option.some _ => true
    }

/// The host: ask the broker for a ticket.
def coop_host (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    if coop_busy m
    then settled m
    else Pair.pair { m with wants_host := true } (Command.perform WebFx.ticket)

/// The join field changed: remember it. (`with_code` is the native, tested
/// half; this only threads it.)
def with_code_typed (m : WebModel) (code : String) : WebModel :=
    { m with coop := with_code m.coop code }

/// The guest submitted the typed code: validate it, then open a socket (asking
/// for a ticket first if there is none).
def coop_join (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    let m2 : WebModel := { m with coop := coop_code_note m.coop } in
    if Bool.not (coop_code_ok m2.coop) then settled m2
    else if coop_busy m2 then settled m2
    else coop_open_for m2

/// Leave deliberately.
def coop_leave (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    let m1 : WebModel :=
        { m with coop := end_session m.coop, socket := Option.none, wants_host := false } in
    let cmd : Command WebFx WebMsg :=
        (match m.socket {
            Option.none => Command.none,
            Option.some w => Command.perform (WebFx.send_text w (net_encode (NetMsg.left "you left the game")))
        }) in
    Pair.pair m1 cmd

/// Open a socket for the code the player typed, asking for a ticket if needed.
def coop_open_for (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    let url : String := coop_url m.coop in
    if String.length url == 0 then Pair.pair m (Command.perform WebFx.ticket)
    else Pair.pair m (Command.perform (WebFx.open_socket url))

/// The code the player typed, validated: an unwell-formed code gets a notice.
def coop_code_ok (c : Coop) : Bool :=
    match join_msg c {
        Option.none => false,
        Option.some _ => true
    }

def coop_code_note (c : Coop) : Coop :=
    if coop_code_ok c then c else with_notice c bad_code_notice

/// The ticket came back: `url` is the socket URL, `""` for a refusal.
def coop_ticket (m : WebModel) (url : String) : Pair WebModel (Command WebFx WebMsg) :=
    let m1 : WebModel := { m with ticket_req := Option.none } in
    if String.length url == 0
    then
        let m2 : WebModel := { m1 with coop := failed m1.coop "could not get a co-op ticket (are you signed in?)" } in
        settled m2
    else
        let m2 : WebModel := { m1 with coop := with_url m1.coop url } in
        Pair.pair m2 (Command.perform (WebFx.open_socket url))

/// The socket opened: say hello, and then create or join if the player has
/// already asked to. (`host` is "asked for a ticket and not joining"; `guest`
/// is "typed a code".) The relay requires `hello` first, either way.
def coop_open (m : WebModel) : Pair WebModel (Command WebFx WebMsg) :=
    match m.socket {
        Option.none => settled m,
        Option.some w => coop_open_with m w
    }

/// Say hello on the open socket `w`, then `create` (a host) or `join <code>`
/// (a guest). `w` arrives as a typed parameter: a `<-`-free binder cannot be
/// read twice inside one `do`-shaped expression.
def coop_open_with (m : WebModel) (w : WebSocket) : Pair WebModel (Command WebFx WebMsg) :=
    let hello_text : String := hello m.coop "" in
    let opening : Command WebFx WebMsg := Command.perform (WebFx.send_text w hello_text) in
    if m.wants_host
    then do_open_with m opening w create_msg
    else
        match join_msg m.coop {
            Option.none => Pair.pair m opening,
            Option.some join_text => do_open_with m opening w join_text
        }

/// Say hello and then the room message (`create` or `join <code>`).
def do_open_with (m : WebModel) (hello_cmd : Command WebFx WebMsg) (w : WebSocket) (text : String)
    : Pair WebModel (Command WebFx WebMsg) :=
    Pair.pair m (Command.batch [ hello_cmd, Command.perform (WebFx.send_text w text) ])

/// A text frame from the socket: fold it into the session model. The world is
/// touched in `stepped_pair`, after the step (see the comment there).
def coop_net (m : WebModel) (text : String) : Pair WebModel (Command WebFx WebMsg) :=
    settled { m with coop := received m.coop text }

/// The socket went away: back to solo with the reason showing, and the world
/// back to the follow AI.
def coop_closed (m : WebModel) (reason : String) : Pair WebModel (Command WebFx WebMsg) :=
    let why : String := if String.length reason == 0 then "the connection closed" else reason in
    let m1 : WebModel :=
        { m with coop := failed m.coop why, socket := Option.none, ticket_req := Option.none,
          wants_host := false } in
    Pair.pair { m1 with world := coop_clear_guest m1.hooks m1.world } Command.none

/// Everything a frame does after (or instead of) drawing: poll the ticket
/// request if one is in flight, and take one queued socket frame.
///
/// The `batch` runs its commands in order, and `after_render` effects see the
/// patched DOM. One socket frame per frame is enough at the wire's 15-20 Hz
/// and keeps the effect total bounded (a `drain` that answers every queued
/// event can re-enter the fold without ever yielding).
def frame_net_cmds (m : WebModel) : List (Command WebFx WebMsg) :=
    List.append (ticket_cmd m) (pump_cmds m.socket)

/// The ticket poll for this frame, while a request is in flight.
def ticket_cmd (m : WebModel) : List (Command WebFx WebMsg) :=
    match m.ticket_req {
        Option.none => List.empty,
        Option.some req => [ Command.after_render (WebFx.poll_ticket req) ]
    }

def pump_cmds (socket : Option WebSocket) : List (Command WebFx WebMsg) :=
    match socket {
        Option.none => List.empty,
        Option.some w => [ Command.after_render (WebFx.pump w) ]
    }

def on_frame (m : WebModel) (t : F64) : Pair WebModel (Command WebFx WebMsg) :=
    let net : List (Command WebFx WebMsg) := frame_net_cmds m in
    match m.renderer {
        Option.none =>
            if m.setting_up
            then Pair.pair ({ m with last_ms := t }) (Command.batch net)
            else
                Pair.pair { m with setting_up := true, last_ms := t }
                    (Command.batch (List.append net [ Command.after_render (WebFx.setup m.app) ])),
        Option.some r =>
            let dt : F64 := dt_between m.last_ms t in
            Pair.pair { m with last_ms := t }
                (Command.batch (List.append net
                    [ Command.after_render (WebFx.step r m.app m.rig m.world m.input dt) ]))
    }

def update (m : WebModel) (msg : WebMsg) : Pair WebModel (Command WebFx WebMsg) :=
    match msg {
        WebMsg.frame t => on_frame m t,
        WebMsg.ready r touch => settled (with_renderer m r touch),
        WebMsg.failed e => settled (with_status m e),
        WebMsg.stepped world vw vh => stepped_pair m world vw vh,
        WebMsg.key code down => settled (key_model m code down),
        WebMsg.pointer kind x y button => settled (pointer_model m kind x y button),
        WebMsg.wheel dy mode => settled (with_input m (input_wheel (input_wheel_pixels dy mode))),
        WebMsg.stick_start id x y => settled (stick_start_model m id x y),
        WebMsg.stick id x y => settled (stick_move_model m id x y),
        WebMsg.stick_release id => settled (stick_release_for m id),
        WebMsg.touch_key code down => settled (touch_model m code down),
        WebMsg.release => settled (release_all m m.held),
        WebMsg.click x y => settled (click_model m x y),
        WebMsg.window_blur => settled (with_input (release_all m m.held) input_focus_lost),
        WebMsg.net text => coop_net m text,
        WebMsg.net_open => coop_open m,
        WebMsg.net_closed reason => coop_closed m reason,
        WebMsg.ticket_started req => settled (with_ticket m req),
        WebMsg.socket_opened w => settled (with_socket m w),
        WebMsg.coop_ticket url => coop_ticket m url,
        WebMsg.poll_again => settled m,
        WebMsg.coop_host => coop_host m,
        WebMsg.coop_code code => settled (with_code_typed m code),
        WebMsg.coop_join => coop_join m,
        WebMsg.coop_leave => coop_leave m,
        WebMsg.noop => settled m
    }

// ── Subscriptions ───────────────────────────────────────────────────

/// The frame loop, the keys (on `window`, so the canvas need not have
/// focus), and blur. Pointer release is per element: a window-wide
/// `pointerup` would release a held stick when the other thumb lifts.
def subscriptions (_m : WebModel) : List (Subscription WebMsg) :=
    [ Subscription.animation_frame (fn (e : WebEvent) => WebMsg.frame e.time_stamp),
      Subscription.window "keydown" (fn (e : WebEvent) => WebMsg.key e.code true),
      Subscription.window "keyup" (fn (e : WebEvent) => WebMsg.key e.code false),
      Subscription.window "blur" (fn (_e : WebEvent) => WebMsg.window_blur) ]

// ── View ────────────────────────────────────────────────────────────

def hud_text (h : Hud) (k : String) : String :=
    match hud_lookup h k {
        Option.some v => v,
        Option.none => ""
    }

def has_text (s : String) : Bool := Bool.not (String.is_empty s)

def hero_mark (hero : String) : String := if hero == "Xiaomao Mo" then "\u{1F431} " else "\u{1F437} "

def title_text (h : Hud) : String :=
    let lvl : String := hud_text h "level-name" in
    let hero : String := hud_text h "hero" in
    let head : String := (if has_text lvl
        then String.concat "Mo Venture · " lvl
        else "Mo Venture") in
    if has_text hero then String.concat head (String.concat " · " (String.concat (hero_mark hero) hero))
    else head

def panel_title (h : Hud) : Oak.Node WebMsg :=
    Html.div [Html.id_ "hud-title", Html.class_ ["forge-panel"]]
        [Html.text (title_text h)]

/// One live value: its label, then the value in `#hud-<key>` (what tests
/// and page scripts read, beside what the player sees).
def stat (key : String) (label : String) (value : String) : Oak.Node WebMsg :=
    Html.div [Html.class_ ["forge-stat"]]
        [Html.span [Html.class_ ["forge-label"]] [Html.text label],
         Html.span [Html.id_ (String.concat "hud-" key)] [Html.text value]]

def panel_stats (h : Hud) : Oak.Node WebMsg :=
    Ui.row List.empty [Html.id_ "hud-stats", Html.class_ ["forge-panel"]]
        [stat "sparks" "sparks" (hud_text h "sparks"),
         stat "time" "time" (hud_text h "time"),
         stat "falls" "falls" (hud_text h "falls")]

/// The game's message line (empty most of the time) and, beside it, the
/// headless position readout (`#hud-pos`) the smoke test follows Mo by.
def panel_message (h : Hud) : Oak.Node WebMsg :=
    let msg : String := hud_text h "message" in
    let cls : List String := if has_text msg then ["forge-panel"] else ["forge-panel", "forge-hidden"] in
    Html.div [Html.id_ "hud-message", Html.class_ cls]
        [Html.text msg,
         Html.span [Html.id_ "hud-pos", Html.class_ ["forge-hidden"]]
             [Html.text (hud_text h "pos")]]

/// A setup failure (no WebGL, a shader error), where a player can see it.
def status_node (m : WebModel) : Oak.Node WebMsg :=
    if m.status == "" || m.status == "ok"
    then Html.span [Html.class_ ["forge-hidden"]] List.empty
    else Html.div [Html.id_ "forge-status", Html.class_ ["forge-panel", "forge-error"]]
             [Html.text (String.concat "forge: " m.status)]

def key_cap (k : String) : Oak.Node WebMsg := Html.kbd [Html.class_ ["forge-key"]] [Html.text k]

def help_panel : Oak.Node WebMsg :=
    Html.div [Html.id_ "hud-help", Html.class_ ["forge-panel"]]
        [Html.div List.empty
            [key_cap "W", key_cap "A", key_cap "S", key_cap "D", Html.text " / arrows: run",
             Html.text " · ", key_cap "Space", Html.text ": jump (hold for height, again in the air)",
             Html.text " · ", key_cap "Shift", Html.text ": sprint / air dash"],
         Html.div List.empty
            [Html.text "right-drag, ", key_cap "Q", key_cap "E", Html.text ": camera · wheel: zoom",
             Html.text " · ", key_cap "P", Html.text ": autopilot · ", key_cap "1", Html.text "–",
             key_cap "6", Html.text ": level"],
         Html.div List.empty
            [key_cap "X", Html.text ": ability (Xiaozhu slams, Xiaomao spins) · ",
             key_cap "C", Html.text ": swap control · ", key_cap "Backspace", Html.text ": restart · ",
             key_cap "Enter", Html.text ": next level"]]

def tbutton (id : String) (cls : List String) (label : String) (code : String) : Oak.Node WebMsg :=
    Html.button
        [ Html.id_ id, Html.class_ cls, Html.attr "type" "button",
          Html.on "pointerdown" ({ prevent_default := true })
              (fn (_e : WebEvent) => HandlerResult.prevent (WebMsg.touch_key code true)),
          Html.on_pointerup (fn (_e : WebEvent) => WebMsg.touch_key code false),
          Html.on "pointerleave" ListenerFlags.none
              (fn (_e : WebEvent) => HandlerResult.msg (WebMsg.touch_key code false)),
          Html.on "pointercancel" ListenerFlags.none
              (fn (_e : WebEvent) => HandlerResult.msg (WebMsg.touch_key code false)) ]
        [Html.text label]

def knob_style (m : WebModel) : String :=
    String.concat "transform: translate("
        (String.concat (F64.to_string m.knob_x) (String.concat "px, " (String.concat (F64.to_string m.knob_y) "px)")))

def stick_node (m : WebModel) : Oak.Node WebMsg :=
    Html.div
        [ Html.id_ "stick", Html.class_ ["stick"],
          Html.on "pointerdown" ({ prevent_default := true })
              (fn (e : WebEvent) => HandlerResult.prevent (stick_start_msg e)),
          Html.on_pointermove stick_move_msg,
          Html.on_pointerup stick_release_msg,
          Html.on "pointerleave" ListenerFlags.none stick_release_hr,
          Html.on "pointercancel" ListenerFlags.none stick_release_hr ]
        [Html.div [Html.id_ "knob", Html.class_ ["knob"], Html.style_attr (knob_style m)] List.empty]

def touch_ui (m : WebModel) (h : Hud) : Oak.Node WebMsg :=
    Html.div [Html.id_ "touch", Html.class_ ["forge-touch"],
              Html.on "contextmenu" ({ prevent_default := true })
                  (fn (_e : WebEvent) => HandlerResult.prevent WebMsg.noop)]
        [ stick_node m,
          tbutton "t-jump" ["tbtn", "tbtn-jump"] "JUMP" "Space",
          tbutton "t-dash" ["tbtn", "tbtn-dash"] "DASH" "ShiftLeft",
          tbutton "t-camleft" ["tbtn", "tbtn-camleft"] "◀" "KeyQ",
          tbutton "t-camright" ["tbtn", "tbtn-camright"] "▶" "KeyE",
          tbutton "t-ability" ["tbtn", "tbtn-ability"] (ability_label h) "KeyX",
          tbutton "t-hero" ["tbtn", "tbtn-small", "tbtn-right-1"] "SWAP" "KeyC",
          tbutton "t-pilot" ["tbtn", "tbtn-small", "tbtn-right-2"] "P" "KeyP",
          tbutton "t-restart" ["tbtn", "tbtn-small", "tbtn-right-3"] "↺" "Backspace",
          tbutton "t-next" ["tbtn", "tbtn-small", "tbtn-right-4"] "▶▶" "Enter" ]

// ── The co-op panel ─────────────────────────────────────────────────
//
// Solo: Host, and a field to join. Hosting: the code to read out, and Leave.
// Both: a line naming the peer, and the relay's last notice.

def coop_button (id : String) (label : String) (msg : WebMsg) : Oak.Node WebMsg :=
    Html.button
        [ Html.id_ id, Html.class_ ["forge-cbtn"], Html.attr "type" "button",
          Html.on_click msg ]
        [Html.text label]

/// The joining field: an ordinary text input (no key subscription of its own;
/// the window keydown handler does not care, and the room code is short).
def coop_join_field : Oak.Node WebMsg :=
    Html.input
        [ Html.id_ "coop-input", Html.class_ ["forge-cinput"], Html.attr "type" "text",
          Html.attr "maxlength" "4", Html.attr "autocomplete" "off",
          Html.attr "autocapitalize" "off", Html.attr "spellcheck" "false",
          Html.placeholder "code", Html.on_input (fn (code : String) => WebMsg.coop_code code) ]

def coop_panel (m : WebModel) : Oak.Node WebMsg :=
    let code : String := display_code m.coop in
    let notice : String := coop_notice m.coop in
    let peer : String := state_line m.coop in
    let has_code : Bool := Bool.not (String.is_empty code) in
    Html.div [Html.id_ "coop", Html.class_ ["forge-panel", "forge-coop"]]
        [ Html.div [Html.id_ "coop-title", Html.class_ ["forge-coop-title"]]
              [Html.text (if is_solo (coop_role m.coop) then "co-op" else "co-op · connected")],
          (if has_code
           then Html.div List.empty
                    [Html.span [Html.class_ ["forge-label"]] [Html.text "code "],
                     Html.span [Html.id_ "coop-code", Html.class_ ["forge-code"]] [Html.text code]]
           else Html.span [Html.id_ "coop-code", Html.class_ ["forge-hidden"]] List.empty),
          (if is_solo (coop_role m.coop)
           then Html.div List.empty [ coop_button "coop-host" "Host" WebMsg.coop_host ]
           else Html.div List.empty [ coop_button "coop-leave" "Leave" WebMsg.coop_leave ]),
          Html.div List.empty [ coop_join_field, coop_button "coop-join" "Join" WebMsg.coop_join ],
          (if String.is_empty notice
           then Html.span [Html.id_ "coop-notice", Html.class_ ["forge-hidden"]] List.empty
           else Html.div [Html.id_ "coop-notice", Html.class_ ["forge-notice"]] [Html.text notice]),
          Html.div [Html.id_ "coop-peer", Html.class_ ["forge-label"]] [Html.text peer] ]

/// The ability button says what `X` does for the controlled hero.
def ability_label (h : Hud) : String :=
    if hud_text h "hero" == "Xiaomao Mo" then "SPIN" else "SLAM"

def canvas_node : Oak.Node WebMsg :=
    Html.canvas
        [ Html.id_ "forge", Html.class_ ["forge-canvas"],
          Html.attr "tabindex" "0",
          Html.on_pointerdown (pointer_msg "down"),
          Html.on_pointerup (pointer_msg "up"),
          Html.on_pointermove (pointer_msg "move"),
          Html.on_pointerleave (WebMsg.pointer "leave" 0.0 0.0 0),
          Html.on_click_with click_msg,
          Html.on "contextmenu" ({ prevent_default := true })
              (fn (_e : WebEvent) => HandlerResult.prevent WebMsg.noop),
          Html.on "wheel" ({ prevent_default := true })
              (fn (e : WebEvent) => HandlerResult.prevent (wheel_msg e)) ]
        List.empty

/// The page. `#forge` keeps its position across renders (no keys, one
/// canvas), so its GL context survives every patch.
def view (m : WebModel) : Oak.Node WebMsg :=
    let h : Hud := world_hud m.world in
    Html.div [Html.id_ "app", Html.class_ ["forge-app"]]
        [ Html.style List.empty m.css,
          canvas_node,
          panel_title h,
          panel_stats h,
          panel_message h,
          status_node m,
          coop_panel m,
          Html.span [Html.id_ "picked", Html.class_ ["forge-hidden"]]
              [Html.text (I64.to_string m.picked)],
          (if m.touch then touch_ui m h else help_panel) ]

/// forge's own layout: the canvas fills the viewport, the HUD sits over it,
/// and the touch controls sit at the bottom corners. The oak_ui stylesheet
/// (cached in `WebModel.css` at mount) themes the panels; these rules only
/// place them.
def forge_css : String :=
    String.concat_list
        [
          "html, body { height: 100%; margin: 0; overflow: hidden; background: #8ec5f0; }\n",
          "#app { height: 100%; }\n",
          ".forge-canvas { position: fixed; inset: 0; width: 100vw; height: 100vh; display: block; touch-action: none; outline: none; }\n",
          ".forge-panel { position: fixed; background: rgba(12, 24, 48, .55); color: #fff; border-radius: 10px; padding: .45rem .7rem; font-size: 14px; line-height: 1.6; pointer-events: none; z-index: 1; }\n",
          "#hud-title { top: .8rem; left: .8rem; font-weight: 700; letter-spacing: .04em; }\n",
          "#hud-stats { top: .8rem; right: .8rem; gap: 1rem; }\n",
          ".forge-stat { display: flex; gap: .35rem; align-items: baseline; }\n",
          ".forge-label { opacity: .7; }\n",
          "#hud-message { top: 3.4rem; left: 50%; transform: translateX(-50%); font-weight: 600; }\n",
          "#hud-help { left: .8rem; bottom: .8rem; font-size: 13px; max-width: 64ch; }\n",
          ".forge-key, #hud-help kbd { font: 12px ui-monospace, monospace; padding: 0 .32em; border: 1px solid #9ab; border-radius: 4px; margin-right: .15em; }\n",
          ".forge-hidden { display: none; }\n",
          ".stick { position: fixed; left: 1.2rem; bottom: 1.2rem; width: 156px; height: 156px; border-radius: 50%; background: rgba(10, 20, 40, .28); border: 2px solid rgba(255, 255, 255, .35); touch-action: none; z-index: 2; }\n",
          ".knob { pointer-events: none; position: absolute; left: 50%; top: 50%; width: 64px; height: 64px; margin: -32px 0 0 -32px; border-radius: 50%; background: rgba(255, 255, 255, .5); }\n",
          ".tbtn { position: fixed; z-index: 2; border-radius: 50%; border: 2px solid rgba(255, 255, 255, .45); background: rgba(10, 20, 40, .35); color: #fff; font-weight: 700; font-size: 16px; touch-action: none; }\n",
          "#touch, #touch * { user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; -webkit-tap-highlight-color: transparent; }\n",
          ".tbtn-jump { right: 1.4rem; bottom: 1.6rem; width: 88px; height: 88px; }\n",
          ".tbtn-dash { right: 8rem; bottom: 1.1rem; width: 72px; height: 72px; }\n",
          ".tbtn-camleft { right: 7.7rem; bottom: 7rem; width: 56px; height: 56px; }\n",
          ".tbtn-camright { right: 2.7rem; bottom: 8.6rem; width: 56px; height: 56px; }\n",
          ".tbtn-small { top: 4.2rem; width: 48px; height: 48px; font-size: 13px; }\n",
          ".tbtn-right-1 { right: .9rem; } .tbtn-right-2 { right: 4.1rem; } .tbtn-right-3 { right: 7.3rem; } .tbtn-right-4 { right: 10.5rem; }\n",          "#coop { right: .8rem; bottom: .8rem; pointer-events: auto; display: flex; flex-direction: column; gap: .3rem; align-items: flex-end; }\n",
          ".forge-coop-title { font-weight: 700; letter-spacing: .04em; opacity: .8; }\n",
          ".forge-code { font: 700 16px ui-monospace, monospace; letter-spacing: .18em; text-transform: uppercase; }\n",
          ".forge-cbtn { border-radius: 6px; border: 1px solid rgba(255, 255, 255, .45); background: rgba(255, 255, 255, .12); color: #fff; font: inherit; padding: .15rem .6rem; cursor: pointer; }\n",
          ".forge-cinput { width: 5.2rem; border-radius: 6px; border: 1px solid rgba(255, 255, 255, .45); background: rgba(0, 0, 0, .25); color: #fff; font: 700 14px ui-monospace, monospace; letter-spacing: .18em; text-transform: uppercase; padding: .15rem .4rem; }\n",
          ".forge-notice { color: #ffd9a0; max-width: 22ch; }\n",
          "" ]

// ── Effects ─────────────────────────────────────────────────────────

/// Bring up WebGL on the view's canvas and learn whether this is a touch
/// screen.
def setup_effect (a : App) : IO (Option WebMsg) := do {
    let assets : Assets := app_assets a;
    let canvas <- Dom.query "#forge";
    let created <- webgl_attach canvas assets;
    match created {
        Result.err e => do {
            let text : String := String.concat "forge: " e;
            let _ <- Console.log text;
            return (Option.some (WebMsg.failed text))
        },
        Result.ok r => do {
            let coarse <- Media.matches "(pointer: coarse)";
            let any <- Media.matches "(any-pointer: coarse)";
            return (Option.some (WebMsg.ready r (coarse || any)))
        },
    }
}

/// The rig to view `world` with: the one a system published there (an orbit
/// camera), else the fallback.
def rig_for (rig : CameraRig) (world : World) : CameraRig := world_camera_rig world rig

def view_of (rig : CameraRig) (world : World) (vw : F64) (vh : F64) : Camera :=
    let r : CameraRig := rig_for rig world in
    rig_camera r vw vh

/// One frame: fit, step the app with this frame's input, submit the plan.
def step_effect (r : WebGlRenderer) (a : App) (rig : CameraRig) (world : World) (input : Input)
    (dt : F64) : IO (Option WebMsg) := do {
    let _ <- webgl_resize r;
    let size <- webgl_client_size r;
    let f : Frame := app_frame_viewed a world input dt (fn (w : World) => view_of rig w (size_width size) (size_height size));
    let plan : FramePlan := app_plan a f;
    let _ <- webgl_submit r plan;
    return (Option.some (WebMsg.stepped (frame_world f) (size_width size) (size_height size)))
}

// ── The co-op effects ───────────────────────────────────────────────
//
// A browser fetch resolves between frames and a socket completes in the
// background, so none of these waits: each starts (or polls, or reads) one
// step and returns.

/// Ask the broker for a socket ticket.
def ticket_effect : IO (Option WebMsg) := do {
    let origin <- Window.origin;
    let url : String := String.concat origin path_ws_ticket;
    let req <- Fetch.begin url 0i64 "";
    IO.pure (Option.some (WebMsg.ticket_started req))
}

/// `{"path":"/api/ws/<ticket>"}` -> `ws://origin/api/ws/<ticket>`. Anything
/// else answers `""`, which the model shows as a refusal.
def ticket_url (origin : String) (body : String) : String :=
    match Json.parse body {
        Result.err _ => "",
        Result.ok j0 =>
            let j : Json := j0 in
            match Json.get_object j {
                Result.err _ => "",
                Result.ok o =>
                    match Json.object_get "path" o {
                        Option.none => "",
                        Option.some v =>
                            match Json.get_str v {
                                Result.err _ => "",
                                Result.ok path => socket_url origin path
                            }
                    }
            }
    }

/// One poll of the ticket request: still pending means come back next frame.
def poll_ticket_effect (req : RequestId) : IO (Option WebMsg) := do {
    let state <- Fetch.poll req;
    if state == 0i64 then IO.pure (Option.some (WebMsg.poll_again))
    else if Bool.not (state == 1i64) then IO.pure (Option.some (WebMsg.coop_ticket ""))
    else do {
        let status <- Fetch.status req;
        if Bool.not (status == 200i64) then IO.pure (Option.some (WebMsg.coop_ticket ""))
        else do {
            let origin <- Window.origin;
            let body <- Fetch.read req 4096i64;
            IO.pure (Option.some (WebMsg.coop_ticket (ticket_url origin body)))
        }
    }
}

/// Open the socket. It completes in the background, so this only stores the
/// handle; the `opened` event arrives through the per-frame drain.
def socket_effect (url : String) : IO (Option WebMsg) := do {
    let w <- WebSocket.connect url [coop_protocol_name];
    IO.pure (Option.some (WebMsg.socket_opened w))
}

def send_text_effect (w : WebSocket) (text : String) : IO (Option WebMsg) := do {
    let _ <- WebSocket.send w (WsData.text text);
    IO.pure Option.none
}

/// A socket event as the message that folds it in.
def ws_msg (ev : WsEvent) : WebMsg :=
    match ev {
        WsEvent.opened _protocol => WebMsg.net_open,
        WsEvent.message d => WebMsg.net (WsData.text_of d),
        WsEvent.closed _code reason _clean => WebMsg.net_closed reason,
        WsEvent.failed => WebMsg.net_closed "could not reach the co-op server"
    }

/// Take ONE queued event off the socket. One per frame, not a drain loop: an
/// effect that answers every queued event can re-enter the fold without ever
/// yielding (and a socket opened before a burst of frames has a long queue).
def pump_effect (w : WebSocket) : IO (Option WebMsg) := do {
    let ev <- WebSocket.next w;
    match ev {
        Option.none => IO.pure Option.none,
        Option.some e => IO.pure (Option.some (ws_msg e))
    }
}

def run_fx (fx : WebFx) : IO (Option WebMsg) :=
    match fx {
        WebFx.setup a => setup_effect a,
        WebFx.step r a rig world input dt => step_effect r a rig world input dt,
        WebFx.ticket => ticket_effect,
        WebFx.poll_ticket req => poll_ticket_effect req,
        WebFx.open_socket url => socket_effect url,
        WebFx.send_text w text => send_text_effect w text,
        WebFx.pump w => pump_effect w
    }

def web_host : Host IO WebFx WebMsg := Host.host run_fx

// ── The program and the exports ─────────────────────────────────────

/// The page as an Oak program over `a` and `rig` (mount only).
pub def web_program (a : App) (rig : CameraRig) (hooks : CoopHooks) : Program WebModel WebMsg WebFx :=
    Program.with_subs (model_new a rig hooks) update view subscriptions

/// The program a tick needs. `Runtime.tick` reads only update/view/
/// subscriptions from it; the mounted model is in oak's state, so `init` is
/// never used after `Runtime.mount`. A blank, cheap model keeps the app and
/// the level out of the per-frame path.
pub def web_program_blank : Program WebModel WebMsg WebFx :=
    Program.with_subs model_blank update view subscriptions

/// The `oak_mount` body. The hooks are the game's half of co-op (its state
/// frame, its own intent); the demo passes `coop_hooks_none`.
pub def web_mount (a : App) (rig : CameraRig) (hooks : CoopHooks) : IO Unit :=
    Runtime.mount (web_program a rig hooks)

/// The `oak_dispatch_event` body.
pub def web_dispatch (handler : I64) : IO Unit := Runtime.dispatch handler

/// The `oak_tick` body. Takes no app: the arguments would be evaluated on
/// every tick (Monad is strict), rebuilding the app and its level for a
/// value `Runtime.tick` discards.
pub def web_tick : IO Unit := Runtime.tick web_program_blank web_host
