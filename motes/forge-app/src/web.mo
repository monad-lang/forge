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
use web_wasm::media {Media.matches}
use web_wasm::console {Console.log}
use oak {WebEvent, ListenerFlags, HandlerResult, Subscription}
use oak::typed {Oak.Node}
use oak::elements {
    Html.attr, Html.button, Html.canvas, Html.class_, Html.div, Html.id_, Html.kbd, Html.span,
    Html.style, Html.style_attr, Html.text
}
use oak::events {
    Html.on, Html.on_click_with, Html.on_pointerdown, Html.on_pointerup, Html.on_pointermove,
    Html.on_pointerleave, Html.on_pointercancel, Html.on_wheel
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
use lib::input {
    Input, InputEvent, input_empty, input_apply, input_end_frame,
    input_key_down, input_key_up, input_pointer_move, input_pointer_down, input_pointer_up,
    input_pointer_leave, input_wheel, input_focus_lost, input_wheel_pixels
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
    css : String
}

pub instance Copy WebModel {
    def copy (m : WebModel) : Pair WebModel WebModel := Pair.pair m m
}

def model_new_with (a : App) (rig : CameraRig) (css : String) : WebModel :=
    { app := a, rig := rig, world := app_initial_world a, input := input_empty,
      last_ms := 0.0 - 1.0, renderer := Option.none, status := "", picked := 0 - 1,
      vw := 1.0, vh := 1.0, touch := false, setting_up := false, knob_x := 0.0, knob_y := 0.0,
      held := List.empty, stick_id := 0 - 1, css := css : WebModel }

/// The mounted model. The stylesheet is static (two fixed themes), so it is
/// built here, once, rather than in `view` on every render.
def model_new (a : App) (rig : CameraRig) : WebModel :=
    model_new_with a rig
        (String.concat (Ui.stylesheet_auto Ui.Theme.light Ui.Theme.dark) forge_css)

/// The tick's program needs an init value it never uses (the mounted model
/// is in oak's state; `Runtime.tick` reads only update/view/subscriptions).
/// Keep it cheap: no app or level construction.
def model_blank : WebModel := model_new_with app_new (camera_rig v3_zero v3_zero 1.0) ""

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
    noop
}

// ── Effects ─────────────────────────────────────────────────────────

/// What the page asks the host to do. Everything IO lives here; `update`
/// and `view` stay pure.
pub type WebFx {
    setup (app : App),
    step (r : WebGlRenderer) (app : App) (rig : CameraRig) (world : World) (input : Input) (dt : F64)
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

def on_frame (m : WebModel) (t : F64) : Pair WebModel (Command WebFx WebMsg) :=
    match m.renderer {
        Option.none =>
            if m.setting_up
            then Pair.pair ({ m with last_ms := t }) Command.none
            else Pair.pair { m with setting_up := true, last_ms := t }
                     (Command.after_render (WebFx.setup m.app)),
        Option.some r =>
            let dt : F64 := dt_between m.last_ms t in
            Pair.pair { m with last_ms := t }
                (Command.after_render (WebFx.step r m.app m.rig m.world m.input dt))
    }

def update (m : WebModel) (msg : WebMsg) : Pair WebModel (Command WebFx WebMsg) :=
    match msg {
        WebMsg.frame t => on_frame m t,
        WebMsg.ready r touch =>
            Pair.pair ({ m with renderer := Option.some r, touch := touch, status := "ok" }) Command.none,
        WebMsg.failed e => Pair.pair ({ m with status := e }) Command.none,
        WebMsg.stepped world vw vh =>
            Pair.pair ({ m with world := world, vw := vw, vh := vh, input := input_end_frame m.input }) Command.none,
        WebMsg.key code down => Pair.pair (key_model m code down) Command.none,
        WebMsg.pointer kind x y button => Pair.pair (pointer_model m kind x y button) Command.none,
        WebMsg.wheel dy mode => Pair.pair (with_input m (input_wheel (input_wheel_pixels dy mode))) Command.none,
        WebMsg.stick_start id x y => Pair.pair (stick_start_model m id x y) Command.none,
        WebMsg.stick id x y => Pair.pair (stick_move_model m id x y) Command.none,
        WebMsg.stick_release id => Pair.pair (stick_release_for m id) Command.none,
        WebMsg.touch_key code down => Pair.pair (touch_model m code down) Command.none,
        WebMsg.release => Pair.pair (release_all m m.held) Command.none,
        WebMsg.click x y => Pair.pair (click_model m x y) Command.none,
        WebMsg.window_blur => Pair.pair (with_input (release_all m m.held) input_focus_lost) Command.none,
        WebMsg.noop => Pair.pair m Command.none
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
          ".tbtn-right-1 { right: .9rem; } .tbtn-right-2 { right: 4.1rem; } .tbtn-right-3 { right: 7.3rem; } .tbtn-right-4 { right: 10.5rem; }\n",
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

def run_fx (fx : WebFx) : IO (Option WebMsg) :=
    match fx {
        WebFx.setup a => setup_effect a,
        WebFx.step r a rig world input dt => step_effect r a rig world input dt,
    }

def web_host : Host IO WebFx WebMsg := Host.host run_fx

// ── The program and the exports ─────────────────────────────────────

/// The page as an Oak program over `a` and `rig` (mount only).
pub def web_program (a : App) (rig : CameraRig) : Program WebModel WebMsg WebFx :=
    Program.with_subs (model_new a rig) update view subscriptions

/// The program a tick needs. `Runtime.tick` reads only update/view/
/// subscriptions from it; the mounted model is in oak's state, so `init` is
/// never used after `Runtime.mount`. A blank, cheap model keeps the app and
/// the level out of the per-frame path.
pub def web_program_blank : Program WebModel WebMsg WebFx :=
    Program.with_subs model_blank update view subscriptions

/// The `oak_mount` body.
pub def web_mount (a : App) (rig : CameraRig) : IO Unit := Runtime.mount (web_program a rig)

/// The `oak_dispatch_event` body.
pub def web_dispatch (handler : I64) : IO Unit := Runtime.dispatch handler

/// The `oak_tick` body. Takes no app: the arguments would be evaluated on
/// every tick (Monad is strict), rebuilding the app and its level for a
/// value `Runtime.tick` discards.
pub def web_tick : IO Unit := Runtime.tick web_program_blank web_host
