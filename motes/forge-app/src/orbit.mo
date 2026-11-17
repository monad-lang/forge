// forge-app: an orbit camera driven by `Input`. Native and tested; the web
// host only reads the `CameraRig` it publishes.
//
// The camera circles `target` at `distance`, at angle `yaw` about +y (0 puts
// the eye on +z, looking down -z) and `pitch` above the horizon. A game adds
// it with `app_add_orbit_camera app orbit`; each frame the system:
//   - rotates by a secondary- or middle-button drag (`orbit_drag_speed`
//     radians per pixel) and by Q/E (yaw) and R/F (pitch) at
//     `orbit_key_speed` radians per second;
//   - zooms by the wheel (each wheel pixel scales the distance by
//     `orbit_zoom_speed`), clamped to `[min_distance, max_distance]`;
//   - stores the new `Orbit` and its `CameraRig` as world resources
//     (`"forge.orbit"`, `"forge.camera_rig"`).
// The primary button is left alone, so a left click still picks.
//
// A host renders with `world_camera_rig` when one is present (forge_app::web
// does), and a system can steer by the camera with `orbit_forward` /
// `orbit_right` (the demo's WASD does).

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, spawn, empty_world, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM}
use forge_math {
    Vec3, vec3, v3_add, v3_scale, v3_sub, v3_length, f64_sin, f64_cos, f64_clamp, f64_abs
}
use forge_schedule {update_s, world_time, time_delta}
use lib::app {App, CameraRig, camera_rig, app_add_system}
use lib::input {
    Input, input_empty, input_apply, input_apply_all, input_end_frame, world_input, world_set_input,
    input_axis, input_button_held, input_delta_x, input_delta_y, input_wheel_delta,
    input_key_down, input_pointer_move, input_pointer_down, input_wheel,
    button_secondary, button_middle, button_primary
}

/// Radians per pixel of drag.
pub def orbit_drag_speed : F64 := 0.008

/// Radians per second while Q/E or R/F is held.
pub def orbit_key_speed : F64 := 1.8

/// Distance scale per wheel pixel (100 px of wheel: 15% farther).
pub def orbit_zoom_speed : F64 := 0.0015

/// The pitch limit, just short of straight up/down (where `up` degenerates).
pub def orbit_max_pitch : F64 := 1.45

/// Where the camera is, as angles around a target. `Copy`.
pub struct Orbit {
    target : Vec3,
    yaw : F64,
    pitch : F64,
    distance : F64,
    fovy : F64,
    min_distance : F64,
    max_distance : F64
}

pub instance Copy Orbit {
    def copy (o : Orbit) : Pair Orbit Orbit := Pair.pair o o
}

def orbit_mk (target : Vec3) (yaw : F64) (pitch : F64) (distance : F64) (fovy : F64)
    (lo : F64) (hi : F64) : Orbit :=
    { target := target, yaw := yaw, pitch := pitch, distance := distance, fovy := fovy,
      min_distance := lo, max_distance := hi
      : Orbit }

/// An orbit around `target`; zoom is limited to 1.5..50 units.
pub def orbit_new (target : Vec3) (yaw : F64) (pitch : F64) (distance : F64) (fovy : F64) : Orbit :=
    orbit_mk target yaw (f64_clamp (0.0 - orbit_max_pitch) orbit_max_pitch pitch)
        (f64_clamp 1.5 50.0 distance) fovy 1.5 50.0

pub def orbit_with_limits (o : Orbit) (lo : F64) (hi : F64) : Orbit :=
    orbit_mk o.target o.yaw o.pitch (f64_clamp lo hi o.distance) o.fovy lo hi

pub def orbit_target (o : Orbit) : Vec3 := o.target

pub def orbit_yaw (o : Orbit) : F64 := o.yaw

pub def orbit_pitch (o : Orbit) : F64 := o.pitch

pub def orbit_distance (o : Orbit) : F64 := o.distance

/// The camera position.
pub def orbit_eye (o : Orbit) : Vec3 :=
    let cp : F64 := f64_cos o.pitch in
    v3_add o.target
        (v3_scale (vec3 (cp * f64_sin o.yaw) (f64_sin o.pitch) (cp * f64_cos o.yaw)) o.distance)

/// The camera's facing on the ground plane (unit, y = 0).
pub def orbit_forward (o : Orbit) : Vec3 :=
    vec3 (0.0 - f64_sin o.yaw) 0.0 (0.0 - f64_cos o.yaw)

/// The camera's right on the ground plane (unit, y = 0).
pub def orbit_right (o : Orbit) : Vec3 :=
    vec3 (f64_cos o.yaw) 0.0 (0.0 - f64_sin o.yaw)

pub def orbit_rig (o : Orbit) : CameraRig := camera_rig (orbit_eye o) o.target o.fovy

/// One frame of control: drag/keys rotate, the wheel zooms.
pub def orbit_update (o : Orbit) (i : Input) (dt : F64) : Orbit :=
    let dragging : Bool := input_button_held i button_secondary || input_button_held i button_middle in
    let drag_x : F64 := if dragging then input_delta_x i else 0.0 in
    let drag_y : F64 := if dragging then input_delta_y i else 0.0 in
    let yaw : F64 :=
        o.yaw - drag_x * orbit_drag_speed + input_axis i "KeyQ" "KeyE" * orbit_key_speed * dt in
    let pitch : F64 :=
        f64_clamp (0.0 - orbit_max_pitch) orbit_max_pitch
            (o.pitch + drag_y * orbit_drag_speed + input_axis i "KeyF" "KeyR" * orbit_key_speed * dt) in
    let scale : F64 := f64_clamp 0.2 5.0 (1.0 + input_wheel_delta i * orbit_zoom_speed) in
    let distance : F64 := f64_clamp o.min_distance o.max_distance (o.distance * scale) in
    orbit_mk o.target yaw pitch distance o.fovy o.min_distance o.max_distance

// ── World resources ─────────────────────────────────────────────────

pub def orbit_name : String := "forge.orbit"

pub def camera_rig_name : String := "forge.camera_rig"

def as_orbit (v : Any) : Orbit :=
    match v { Any.any x => let o : Orbit := x in o }

def as_rig (v : Any) : CameraRig :=
    match v { Any.any x => let r : CameraRig := x in r }

def holder (world : World) (name : String) : Option Entity :=
    List.first (query_entities world [name] [])

/// Install or replace the singleton resource `name`.
def set_resource (world : World) (name : String) (v : Any) : World :=
    match holder world name {
        Option.some e => insert_component world e name v,
        Option.none => spawned_world (spawn world [Pair.pair name v])
    }

def spawned_world (s : Spawned) : World := s.world

def resource (world : World) (name : String) : Option Any :=
    match holder world name {
        Option.none => Option.none,
        Option.some e => get_component_named world e name
    }

pub def world_orbit_opt (world : World) : Option Orbit :=
    match resource world orbit_name {
        Option.some v => Option.some (as_orbit v),
        Option.none => Option.none
    }

pub def world_set_orbit (world : World) (o : Orbit) : World :=
    set_resource world orbit_name (Any.any o)

/// The camera a host should render with this frame, if a system set one.
pub def world_camera_rig_opt (world : World) : Option CameraRig :=
    match resource world camera_rig_name {
        Option.some v => Option.some (as_rig v),
        Option.none => Option.none
    }

pub def world_set_camera_rig (world : World) (r : CameraRig) : World :=
    set_resource world camera_rig_name (Any.any r)

/// The world's camera rig, else `fallback`.
pub def world_camera_rig (world : World) (fallback : CameraRig) : CameraRig :=
    match world_camera_rig_opt world {
        Option.some r => r,
        Option.none => fallback
    }

// ── The system ──────────────────────────────────────────────────────

def orbit_or (world : World) (initial : Orbit) : Orbit :=
    match world_orbit_opt world {
        Option.some o => o,
        Option.none => initial
    }

def publish (world : World) (o : Orbit) : World :=
    world_set_camera_rig (world_set_orbit world o) (orbit_rig o)

/// Advance the world's orbit (starting from `initial`) by this frame's input.
pub def orbit_step (initial : Orbit) (world : World) : World :=
    publish world
        (orbit_update (orbit_or world initial) (world_input world) (time_delta (world_time world)))

pub def orbit_system (initial : Orbit) : WorldM Id Unit := WorldM.modify (orbit_step initial)

/// Drive the app's camera with an orbit starting at `initial`, as an
/// update-stage system. Until its first run publishes a rig, a host uses its
/// own (`web_mount`'s `rig` argument), so pass `orbit_rig initial` there.
pub def app_add_orbit_camera (a : App) (initial : Orbit) : App :=
    app_add_system a "forge.orbit" update_s (orbit_system initial)

// ── Tests ───────────────────────────────────────────────────────────

def near (a : F64) (b : F64) : Bool := f64_abs (a - b) < 0.000001

def o0 : Orbit := orbit_new (vec3 0.0 0.0 0.0) 0.0 0.0 10.0 1.0

#[test]
def test_eye_at_yaw_zero_is_on_plus_z : Bool :=
    let e : Vec3 := orbit_eye o0 in
    near e.x 0.0 && near e.y 0.0 && near e.z 10.0

#[test]
def test_eye_keeps_distance : Bool :=
    let o : Orbit := orbit_new (vec3 1.0 2.0 3.0) 0.7 0.4 6.0 1.0 in
    f64_abs (v3_length (v3_sub (orbit_eye o) (vec3 1.0 2.0 3.0)) - 6.0) < 0.0001

#[test]
def test_forward_and_right_at_yaw_zero : Bool :=
    let f : Vec3 := orbit_forward o0 in
    let r : Vec3 := orbit_right o0 in
    near f.z (0.0 - 1.0) && near f.x 0.0 && near r.x 1.0 && near r.z 0.0

#[test]
def test_no_input_no_change : Bool :=
    let o : Orbit := orbit_update o0 input_empty 0.016 in
    near o.yaw 0.0 && near o.pitch 0.0 && near o.distance 10.0

#[test]
def test_secondary_drag_rotates : Bool :=
    let i : Input :=
        input_apply_all input_empty
            [input_pointer_move 100.0 100.0, input_pointer_down button_secondary 100.0 100.0,
             input_pointer_move 150.0 80.0] in
    let o : Orbit := orbit_update o0 i 0.016 in
    // 50 px right: yaw -0.4; 20 px up: pitch -0.16
    near o.yaw (0.0 - 0.4) && near o.pitch (0.0 - 0.16)

#[test]
def test_primary_drag_does_not_rotate : Bool :=
    let i : Input :=
        input_apply_all input_empty
            [input_pointer_move 100.0 100.0, input_pointer_down button_primary 100.0 100.0,
             input_pointer_move 150.0 80.0] in
    near (orbit_yaw (orbit_update o0 i 0.016)) 0.0

#[test]
def test_keys_rotate_by_time : Bool :=
    let i : Input := input_apply input_empty (input_key_down "KeyE") in
    near (orbit_yaw (orbit_update o0 i 0.5)) 0.9

#[test]
def test_pitch_is_clamped : Bool :=
    let i : Input := input_apply input_empty (input_key_down "KeyR") in
    near (orbit_pitch (orbit_update o0 i 10.0)) orbit_max_pitch

#[test]
def test_wheel_zooms_and_clamps : Bool :=
    let out : Orbit := orbit_update o0 (input_apply input_empty (input_wheel 100.0)) 0.016 in
    let far : Orbit := orbit_update o0 (input_apply input_empty (input_wheel 100000.0)) 0.016 in
    let close : Orbit :=
        orbit_update (orbit_new (vec3 0.0 0.0 0.0) 0.0 0.0 2.0 1.0)
            (input_apply input_empty (input_wheel (0.0 - 100000.0))) 0.016 in
    near out.distance 11.5 && near far.distance 50.0 && near close.distance 1.5

#[test]
def test_step_publishes_orbit_and_rig : Bool :=
    let w : World := orbit_step o0 (world_set_input empty_world (input_apply input_empty (input_wheel 100.0))) in
    match world_camera_rig_opt w {
        Option.none => false,
        Option.some r0 =>
            let r : CameraRig := r0 in
            near r.eye.z 11.5 && near (orbit_distance (orbit_or w o0)) 11.5
    }

#[test]
def test_rig_falls_back_without_orbit : Bool :=
    let fb : CameraRig := camera_rig (vec3 0.0 1.0 2.0) (vec3 0.0 0.0 0.0) 1.0 in
    let r : CameraRig := world_camera_rig empty_world fb in
    near r.eye.y 1.0
