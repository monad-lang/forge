// forge-app: keyboard and pointer input as a pure world resource.
//
// The model is backend-neutral and natively tested. A host (today the web
// host, `forge_app::web`) translates its events into `InputEvent`s, folds
// them into an `Input` with `input_apply` as they arrive, installs that
// `Input` in the world before the frame runs (`app_frame_input`), and calls
// `input_end_frame` once the frame is done. Systems read it with
// `world_input`, the same singleton-entity resource pattern forge-schedule
// uses for `Time`.
//
// Keys are named by their PHYSICAL code (`KeyboardEvent.code`: "KeyW",
// "ArrowLeft", "Space"), so WASD stays WASD on any keyboard layout. Pointer
// buttons use the DOM numbering: 0 primary, 1 middle (auxiliary), 2
// secondary. Positions are in CSS pixels relative to the canvas, origin top
// left, which is what `camera_screen_ray` takes.
//
// Per frame:
//   held      what is down now (survives across frames)
//   pressed   went down since the last `input_end_frame` (edge; key
//             auto-repeat does NOT re-press a held key)
//   released  went up since the last `input_end_frame` (edge)
//   delta     pointer motion accumulated since the last `input_end_frame`
//   wheel     wheel `deltaY` accumulated likewise (positive scrolls down)
// A key that goes down and up inside one frame shows up in both `pressed`
// and `released`, but not in `held`, so a tap is never lost.

use std::list {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, Spawned, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}

// ── Events ──────────────────────────────────────────────────────────

/// One host input event, already reduced to what the model needs.
pub type InputEvent {
    key_down_ev (code : String),
    key_up_ev (code : String),
    pointer_move_ev (x : F64) (y : F64),
    pointer_down_ev (button : I64) (x : F64) (y : F64),
    pointer_up_ev (button : I64) (x : F64) (y : F64),
    pointer_leave_ev,
    wheel_ev (dy : F64),
    focus_lost_ev
}

pub instance Copy InputEvent {
    def copy (e : InputEvent) : Pair InputEvent InputEvent := Pair.pair e e
}

pub def input_key_down (code : String) : InputEvent := key_down_ev code

pub def input_key_up (code : String) : InputEvent := key_up_ev code

pub def input_pointer_move (x : F64) (y : F64) : InputEvent := pointer_move_ev x y

pub def input_pointer_down (button : I64) (x : F64) (y : F64) : InputEvent := pointer_down_ev button x y

pub def input_pointer_up (button : I64) (x : F64) (y : F64) : InputEvent := pointer_up_ev button x y

pub def input_pointer_leave : InputEvent := pointer_leave_ev

pub def input_wheel (dy : F64) : InputEvent := wheel_ev dy

/// The window lost focus: every held key and button is released (the
/// browser will not send their `keyup`s).
pub def input_focus_lost : InputEvent := focus_lost_ev

/// Pointer button numbers.
pub def button_primary : I64 := 0

pub def button_middle : I64 := 1

pub def button_secondary : I64 := 2

/// A wheel `deltaY` in pixels from the DOM `deltaMode` (0 pixels, 1 lines,
/// 2 pages).
pub def input_wheel_pixels (dy : F64) (mode : I64) : F64 :=
    if mode == 1 then dy * 16.0
    else if mode == 2 then dy * 800.0
    else dy

/// Keys whose browser default (scrolling the page) a game never wants.
pub def input_is_scroll_key (code : String) : Bool :=
    code == "Space" || code == "ArrowUp" || code == "ArrowDown"
        || code == "ArrowLeft" || code == "ArrowRight"

// ── State ───────────────────────────────────────────────────────────

/// The input state one frame sees. `Copy` (identity: persistent fields).
pub struct Input {
    held : List String,
    pressed : List String,
    released : List String,
    buttons : List I64,
    buttons_pressed : List I64,
    buttons_released : List I64,
    pointer_x : F64,
    pointer_y : F64,
    delta_x : F64,
    delta_y : F64,
    wheel : F64,
    inside : Bool
}

pub instance Copy Input {
    def copy (i : Input) : Pair Input Input := Pair.pair i i
}

def input_mk (held : List String) (pressed : List String) (released : List String)
    (buttons : List I64) (buttons_pressed : List I64) (buttons_released : List I64)
    (px : F64) (py : F64) (dx : F64) (dy : F64) (wheel : F64) (inside : Bool) : Input :=
    { held := held, pressed := pressed, released := released,
      buttons := buttons, buttons_pressed := buttons_pressed,
      buttons_released := buttons_released,
      pointer_x := px, pointer_y := py, delta_x := dx, delta_y := dy,
      wheel := wheel, inside := inside
      : Input }

/// Nothing held, pointer at the origin and outside the canvas.
pub def input_empty : Input :=
    input_mk List.empty List.empty List.empty List.empty List.empty List.empty
        0.0 0.0 0.0 0.0 0.0 false

// ── Small set helpers (lists: a handful of keys at most) ────────────

#[terminating]
def has_str (xs : List String) (s : String) : Bool :=
    match xs {
        List.empty => false,
        List.cons x rest => if x == s then true else has_str rest s
    }

/// `xs` with `s` appended unless already present (one pass: `xs` is affine).
#[terminating]
def add_str (xs : List String) (s : String) : List String :=
    match xs {
        List.empty => [s],
        List.cons x rest => if x == s then List.cons x rest else List.cons x (add_str rest s)
    }

#[terminating]
def del_str (xs : List String) (s : String) : List String :=
    match xs {
        List.empty => List.empty,
        List.cons x rest => if x == s then del_str rest s else List.cons x (del_str rest s)
    }

#[terminating]
def has_i64 (xs : List I64) (n : I64) : Bool :=
    match xs {
        List.empty => false,
        List.cons x rest => if x == n then true else has_i64 rest n
    }

#[terminating]
def add_i64 (xs : List I64) (n : I64) : List I64 :=
    match xs {
        List.empty => [n],
        List.cons x rest => if x == n then List.cons x rest else List.cons x (add_i64 rest n)
    }

#[terminating]
def del_i64 (xs : List I64) (n : I64) : List I64 :=
    match xs {
        List.empty => List.empty,
        List.cons x rest => if x == n then del_i64 rest n else List.cons x (del_i64 rest n)
    }

/// Every element of `xs` added to `into`.
#[terminating]
def union_str (into : List String) (xs : List String) : List String :=
    match xs {
        List.empty => into,
        List.cons x rest => union_str (add_str into x) rest
    }

#[terminating]
def union_i64 (into : List I64) (xs : List I64) : List I64 :=
    match xs {
        List.empty => into,
        List.cons x rest => union_i64 (add_i64 into x) rest
    }

// ── Folding events ──────────────────────────────────────────────────

def key_down (i : Input) (code : String) : Input :=
    if has_str i.held code then i
    else input_mk (List.cons code i.held) (add_str i.pressed code) i.released
        i.buttons i.buttons_pressed i.buttons_released
        i.pointer_x i.pointer_y i.delta_x i.delta_y i.wheel i.inside

def key_up (i : Input) (code : String) : Input :=
    if has_str i.held code
    then input_mk (del_str i.held code) i.pressed (add_str i.released code)
        i.buttons i.buttons_pressed i.buttons_released
        i.pointer_x i.pointer_y i.delta_x i.delta_y i.wheel i.inside
    else i

/// Move the pointer to `(x, y)`; the first move after entering does not
/// count as motion (no jump from wherever the pointer left).
def moved (i : Input) (x : F64) (y : F64) : Input :=
    let dx : F64 := if i.inside then x - i.pointer_x else 0.0 in
    let dy : F64 := if i.inside then y - i.pointer_y else 0.0 in
    input_mk i.held i.pressed i.released i.buttons i.buttons_pressed i.buttons_released
        x y (i.delta_x + dx) (i.delta_y + dy) i.wheel true

def button_down (i0 : Input) (b : I64) (x : F64) (y : F64) : Input :=
    let i : Input := moved i0 x y in
    if has_i64 i.buttons b then i
    else input_mk i.held i.pressed i.released
        (List.cons b i.buttons) (add_i64 i.buttons_pressed b) i.buttons_released
        i.pointer_x i.pointer_y i.delta_x i.delta_y i.wheel i.inside

def button_up (i0 : Input) (b : I64) (x : F64) (y : F64) : Input :=
    let i : Input := moved i0 x y in
    if has_i64 i.buttons b
    then input_mk i.held i.pressed i.released
        (del_i64 i.buttons b) i.buttons_pressed (add_i64 i.buttons_released b)
        i.pointer_x i.pointer_y i.delta_x i.delta_y i.wheel i.inside
    else i

def left (i : Input) : Input :=
    input_mk i.held i.pressed i.released i.buttons i.buttons_pressed i.buttons_released
        i.pointer_x i.pointer_y i.delta_x i.delta_y i.wheel false

def scrolled (i : Input) (dy : F64) : Input :=
    input_mk i.held i.pressed i.released i.buttons i.buttons_pressed i.buttons_released
        i.pointer_x i.pointer_y i.delta_x i.delta_y (i.wheel + dy) i.inside

def lost_focus (i : Input) : Input :=
    input_mk List.empty i.pressed (union_str i.released i.held)
        List.empty i.buttons_pressed (union_i64 i.buttons_released i.buttons)
        i.pointer_x i.pointer_y i.delta_x i.delta_y i.wheel i.inside

/// Fold one event into the state.
pub def input_apply (i : Input) (e : InputEvent) : Input :=
    match e {
        InputEvent.key_down_ev code => key_down i code,
        InputEvent.key_up_ev code => key_up i code,
        InputEvent.pointer_move_ev x y => moved i x y,
        InputEvent.pointer_down_ev b x y => button_down i b x y,
        InputEvent.pointer_up_ev b x y => button_up i b x y,
        InputEvent.pointer_leave_ev => left i,
        InputEvent.wheel_ev dy => scrolled i dy,
        InputEvent.focus_lost_ev => lost_focus i
    }

/// Fold events in order.
#[terminating]
pub def input_apply_all (i : Input) (es : List InputEvent) : Input :=
    match es {
        List.empty => i,
        List.cons e rest => input_apply_all (input_apply i e) rest
    }

/// Close a frame: clear the edges and the accumulated motion, keep what is
/// held and where the pointer is.
pub def input_end_frame (i : Input) : Input :=
    input_mk i.held List.empty List.empty i.buttons List.empty List.empty
        i.pointer_x i.pointer_y 0.0 0.0 0.0 i.inside

// ── Queries ─────────────────────────────────────────────────────────

pub def input_key_held (i : Input) (code : String) : Bool := has_str i.held code

pub def input_key_pressed (i : Input) (code : String) : Bool := has_str i.pressed code

pub def input_key_released (i : Input) (code : String) : Bool := has_str i.released code

pub def input_button_held (i : Input) (b : I64) : Bool := has_i64 i.buttons b

pub def input_button_pressed (i : Input) (b : I64) : Bool := has_i64 i.buttons_pressed b

pub def input_button_released (i : Input) (b : I64) : Bool := has_i64 i.buttons_released b

pub def input_pointer_x (i : Input) : F64 := i.pointer_x

pub def input_pointer_y (i : Input) : F64 := i.pointer_y

pub def input_delta_x (i : Input) : F64 := i.delta_x

pub def input_delta_y (i : Input) : F64 := i.delta_y

pub def input_wheel_delta (i : Input) : F64 := i.wheel

/// Whether the pointer is over the canvas.
pub def input_pointer_inside (i : Input) : Bool := i.inside

/// The codes held now (most recent first).
pub def input_held_keys (i : Input) : List String := i.held

/// -1, 0 or +1 from a negative/positive key pair: `input_axis i "KeyA" "KeyD"`.
pub def input_axis (i : Input) (neg : String) (pos : String) : F64 :=
    let n : F64 := if has_str i.held neg then 1.0 else 0.0 in
    let p : F64 := if has_str i.held pos then 1.0 else 0.0 in
    p - n

// ── World resource ──────────────────────────────────────────────────

pub def input_name : String := "forge.input"

def as_input (v : Any) : Input :=
    match v { Any.any x => let i : Input := x in i }

def input_of (world : World) (holder : Option Entity) : Option Input :=
    match holder {
        Option.none => Option.none,
        Option.some e =>
            match get_component_named world e input_name {
                Option.some v => Option.some (as_input v),
                Option.none => Option.none
            }
    }

/// The world's input, if a host installed one.
pub def world_input_opt (world : World) : Option Input :=
    input_of world (List.first (query_entities world [input_name] []))

/// The world's input (`input_empty` when none is installed, e.g. natively).
pub def world_input (world : World) : Input :=
    match world_input_opt world {
        Option.some i => i,
        Option.none => input_empty
    }

def spawn_input (world : World) (i : Input) : World :=
    let s : Spawned := spawn world [Pair.pair input_name (Any.any i)] in
    s.world

/// Install or replace the world's input.
pub def world_set_input (world : World) (i : Input) : World :=
    match List.first (query_entities world [input_name] []) {
        Option.some e => insert_component world e input_name (Any.any i),
        Option.none => spawn_input world i
    }

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_empty_holds_nothing : Bool :=
    Bool.not (input_key_held input_empty "KeyW") && Bool.not (input_pointer_inside input_empty)

#[test]
def test_key_down_holds_and_presses : Bool :=
    let i : Input := input_apply input_empty (input_key_down "KeyW") in
    input_key_held i "KeyW" && input_key_pressed i "KeyW" && Bool.not (input_key_released i "KeyW")

#[test]
def test_repeat_does_not_repress : Bool :=
    let i1 : Input := input_end_frame (input_apply input_empty (input_key_down "KeyW")) in
    let i2 : Input := input_apply i1 (input_key_down "KeyW") in
    input_key_held i2 "KeyW" && Bool.not (input_key_pressed i2 "KeyW")
        && List.length (input_held_keys i2) == 1

#[test]
def test_tap_within_a_frame_is_seen : Bool :=
    let i : Input := input_apply_all input_empty [input_key_down "Space", input_key_up "Space"] in
    input_key_pressed i "Space" && input_key_released i "Space" && Bool.not (input_key_held i "Space")

#[test]
def test_end_frame_clears_edges_keeps_held : Bool :=
    let i : Input := input_end_frame (input_apply input_empty (input_key_down "KeyA")) in
    input_key_held i "KeyA" && Bool.not (input_key_pressed i "KeyA")

#[test]
def test_key_up_of_unheld_is_ignored : Bool :=
    let i : Input := input_apply input_empty (input_key_up "KeyQ") in
    Bool.not (input_key_released i "KeyQ")

#[test]
def test_axis : Bool :=
    let i : Input := input_apply_all input_empty [input_key_down "KeyA"] in
    let j : Input := input_apply i (input_key_down "KeyD") in
    input_axis i "KeyA" "KeyD" == 0.0 - 1.0 && input_axis j "KeyA" "KeyD" == 0.0
        && input_axis input_empty "KeyA" "KeyD" == 0.0

#[test]
def test_pointer_motion_accumulates : Bool :=
    let i : Input :=
        input_apply_all input_empty
            [input_pointer_move 10.0 20.0, input_pointer_move 13.0 18.0, input_pointer_move 15.0 25.0] in
    // the first move enters (no motion), the next two add (3,-2) and (2,7)
    input_pointer_x i == 15.0 && input_pointer_y i == 25.0
        && input_delta_x i == 5.0 && input_delta_y i == 5.0 && input_pointer_inside i

#[test]
def test_end_frame_clears_motion_and_wheel : Bool :=
    let i : Input :=
        input_end_frame
            (input_apply_all input_empty
                [input_pointer_move 1.0 1.0, input_pointer_move 4.0 1.0, input_wheel 120.0]) in
    input_delta_x i == 0.0 && input_wheel_delta i == 0.0 && input_pointer_x i == 4.0

#[test]
def test_leave_then_reenter_does_not_jump : Bool :=
    let i : Input :=
        input_apply_all input_empty
            [input_pointer_move 1.0 1.0, input_pointer_leave, input_pointer_move 300.0 1.0] in
    input_delta_x i == 0.0 && input_pointer_inside i

#[test]
def test_buttons : Bool :=
    let i : Input := input_apply input_empty (input_pointer_down button_primary 5.0 6.0) in
    let j : Input := input_apply (input_end_frame i) (input_pointer_up button_primary 5.0 6.0) in
    input_button_held i button_primary && input_button_pressed i button_primary
        && input_pointer_x i == 5.0
        && Bool.not (input_button_held j button_primary) && input_button_released j button_primary
        && Bool.not (input_button_pressed j button_primary)

#[test]
def test_wheel_accumulates : Bool :=
    input_wheel_delta (input_apply_all input_empty [input_wheel 100.0, input_wheel (0.0 - 40.0)]) == 60.0

#[test]
def test_focus_lost_releases_everything : Bool :=
    let i : Input :=
        input_end_frame
            (input_apply_all input_empty
                [input_key_down "KeyW", input_key_down "ShiftLeft", input_pointer_down button_secondary 0.0 0.0]) in
    let j : Input := input_apply i input_focus_lost in
    Bool.not (input_key_held j "KeyW") && input_key_released j "KeyW" && input_key_released j "ShiftLeft"
        && Bool.not (input_button_held j button_secondary) && input_button_released j button_secondary

#[test]
def test_wheel_pixels_and_scroll_keys : Bool :=
    input_wheel_pixels 3.0 1 == 48.0 && input_wheel_pixels 10.0 0 == 10.0
        && input_is_scroll_key "Space" && Bool.not (input_is_scroll_key "KeyW")
