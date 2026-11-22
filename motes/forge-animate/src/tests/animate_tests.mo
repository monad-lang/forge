// forge-animate: tracks, loop modes, crossfade, markers, tweens, and the
// systems over a world.

use lib::{
    Easing, ease, Property, prop_translation, prop_rotation, prop_scale, v4_nlerp_short, v4_of_quat,
    Key, key_f64, key_vec3, key_quat, Track, track, track_f64_at, track_vec3_at, track_quat_at,
    track_duration, Channel, channel, Marker, marker, Clip, clip, clip_timed, LoopMode, loop_once,
    loop_repeat, loop_ping_pong, loop_time, Animator, animator, animator_crossfade, animator_advance,
    animator_weights, animator_local_time, set_animator, animate_by, world_anim_events, AnimEvent,
    anim_event_name, crossed, Tween, TweenEnd, tween_scale, tween_translation, tween_then, end_despawn,
    set_tween, tween_by, entity_tween
}
use forge_core::ecs {World, Entity, Spawned, empty_world, entity_exists}
use forge_math::{Vec3, vec3, v3_zero, v3_one, Vec4, vec4, Quat, quat_identity, quat_from_axis_angle, quat_length, f64_abs}
use forge_scene::{Transform, transform_new, transform_identity, spawn_transform, spawn_transform_child, entity_transform, set_name}

def near (e : F64) (a : F64) (b : F64) : Bool := f64_abs (a - b) < e

// ── Tracks ──────────────────────────────────────────────────────────

def ramp : Track :=
    track Property.prop_translation [key_f64 1.0 10.0 Easing.linear, key_f64 3.0 20.0 Easing.linear, key_f64 4.0 0.0 Easing.step]

#[test]
def test_track_holds_before_and_after : Bool :=
    track_f64_at ramp 0.0 == 10.0 && track_f64_at ramp 1.0 == 10.0 && track_f64_at ramp 9.0 == 0.0
        && track_duration ramp == 4.0

#[test]
def test_track_samples_at_and_between_keys : Bool :=
    near 0.000001 (track_f64_at ramp 2.0) 15.0 && near 0.000001 (track_f64_at ramp 3.0) 20.0
        && near 0.000001 (track_f64_at ramp 2.5) 17.5

#[test]
def test_the_later_keys_easing_shapes_the_segment : Bool :=
    // Into key 3 with `step`: holds 20 until t = 4.
    near 0.000001 (track_f64_at ramp 3.99) 20.0

#[test]
def test_rotation_track_takes_the_short_way : Bool :=
    // 350 degrees about y written as its negated twin; the blend must stay
    // near the start rather than swing the long way round.
    let a : Quat := quat_identity in
    let b0 : Quat := quat_from_axis_angle (vec3 0.0 1.0 0.0) 6.1086524 in
    let tr : Track := track Property.prop_rotation [key_quat 0.0 a Easing.linear, key_quat 1.0 b0 Easing.linear] in
    let mid : Quat := track_quat_at tr 0.5 in
    near 0.000001 (quat_length mid) 1.0 && f64_abs mid.w > 0.99

// ── Loop modes ──────────────────────────────────────────────────────

#[test]
def test_loop_time_modes : Bool :=
    near 0.000001 (loop_time LoopMode.loop_once 5.0 2.0) 2.0
        && near 0.000001 (loop_time LoopMode.loop_repeat 5.0 2.0) 1.0
        && near 0.000001 (loop_time LoopMode.loop_repeat 4.0 2.0) 0.0
        && near 0.000001 (loop_time LoopMode.loop_ping_pong 2.5 2.0) 1.5
        && near 0.000001 (loop_time LoopMode.loop_ping_pong 4.5 2.0) 0.5
        && near 0.000001 (loop_time LoopMode.loop_repeat 100000.25 2.0) 0.25

#[test]
def test_marker_crossings : Bool :=
    crossed LoopMode.loop_repeat 0.5 0.9 0.7 && Bool.not (crossed LoopMode.loop_repeat 0.5 0.9 0.5)
        && crossed LoopMode.loop_repeat 1.9 0.1 0.05 && crossed LoopMode.loop_repeat 1.9 0.1 1.95
        && crossed LoopMode.loop_ping_pong 1.5 1.2 1.3 && Bool.not (crossed LoopMode.loop_once 2.0 2.0 2.0)

// ── Animators in a world ────────────────────────────────────────────

/// Bob: y from 0 up to 1 at t = 1 and back to 0 at t = 2.
def bob : Clip :=
    clip [channel "" (track Property.prop_translation [key_vec3 0.0 v3_zero Easing.linear,
                                                     key_vec3 1.0 (vec3 0.0 1.0 0.0) Easing.linear,
                                                     key_vec3 2.0 v3_zero Easing.linear])]
         [marker 1.0 "top"]

/// Slide: x from 0 to 4 over 2 s (y stays 0).
def slide : Clip :=
    clip [channel "" (track Property.prop_translation [key_vec3 0.0 v3_zero Easing.linear,
                                                     key_vec3 2.0 (vec3 4.0 0.0 0.0) Easing.linear])]
         []

struct One {
    world : World,
    entity : Entity
}

instance Copy One {
    def copy (o : One) : Pair One One := Pair.pair o o
}

def with_animator (a : Animator) : One :=
    let s : Spawned := spawn_transform empty_world transform_identity in
    { world := set_animator s.world s.entity a, entity := s.entity : One }

#[terminating]
def frames (w : World) (dt : F64) (n : I64) : World :=
    if n <= 0 then w else frames (animate_by dt w) dt (n - 1)

def pos (w : World) (e : Entity) : Vec3 :=
    match entity_transform w e {
        Option.some t0 => let t : Transform := t0 in t.translation,
        Option.none => vec3 (0.0 - 99.0) 0.0 0.0
    }

#[test]
def test_animator_follows_the_clip_at_known_times : Bool :=
    let o : One := with_animator (animator bob LoopMode.loop_repeat) in
    let w1 : World := frames o.world 0.25 2 in
    let w2 : World := frames w1 0.25 4 in
    let p1 : Vec3 := pos w1 o.entity in
    let p2 : Vec3 := pos w2 o.entity in
    // t = 0.5: halfway up; t = 1.5: halfway down.
    near 0.000001 p1.y 0.5 && near 0.000001 p2.y 0.5

#[test]
def test_animator_wraps_and_ping_pongs : Bool :=
    let r : One := with_animator (animator slide LoopMode.loop_repeat) in
    let p : One := with_animator (animator slide LoopMode.loop_ping_pong) in
    let a : Vec3 := pos (frames r.world 0.5 5) r.entity in
    let b : Vec3 := pos (frames p.world 0.5 5) p.entity in
    // t = 2.5: repeat is 0.5 into the slide (x = 1), ping-pong 0.5 back (x = 3).
    near 0.000001 a.x 1.0 && near 0.000001 b.x 3.0

#[test]
def test_crossfade_weights_sum_to_one_and_blend : Bool :=
    let a0 : Animator := animator_crossfade (animator bob LoopMode.loop_repeat) slide 1.0 in
    let a1 : Animator := animator_advance a0 0.5 in
    let ws : Pair F64 F64 := animator_weights a1 in
    let ok_weights : Bool := match ws { Pair.pair x y0 => let y : F64 := y0 in near 0.000001 (x + y) 1.0 && near 0.000001 y 0.5 } in
    let o : One := with_animator a0 in
    let w : World := animate_by 0.5 o.world in
    let p : Vec3 := pos w o.entity in
    // bob at 0.5 is (0, 0.5, 0), slide at 0.5 is (1, 0, 0); half and half.
    ok_weights && near 0.000001 p.x 0.5 && near 0.000001 p.y 0.25

#[test]
def test_crossfade_finishes_on_the_next_clip : Bool :=
    let a : Animator := animator_advance (animator_advance (animator_crossfade (animator bob LoopMode.loop_repeat) slide 1.0) 0.6) 0.6 in
    let ws : Pair F64 F64 := animator_weights a in
    match ws { Pair.pair x y => x == 1.0 && y == 0.0 && near 0.000001 (animator_local_time a) 1.2 }

#[test]
def test_markers_emit_events_the_frame_they_are_crossed : Bool :=
    let o : One := with_animator (animator bob LoopMode.loop_repeat) in
    let w1 : World := frames o.world 0.4 2 in
    let w2 : World := animate_by 0.4 w1 in
    // 0.8 -> no event yet; 0.8 -> 1.2 crosses "top".
    List.length (world_anim_events w1) == 0
        && (match List.first (world_anim_events w2) {
                Option.some e => anim_event_name e == "top",
                Option.none => false
            })

#[test]
def test_a_channel_drives_a_named_child : Bool :=
    let root : Spawned := spawn_transform empty_world transform_identity in
    let kid : Spawned := spawn_transform_child root.world transform_identity root.entity in
    let w0 : World := set_name kid.world kid.entity "arm" in
    let c : Clip := clip [channel "arm" (track Property.prop_scale [key_vec3 0.0 v3_one Easing.linear,
                                                               key_vec3 1.0 (vec3 3.0 3.0 3.0) Easing.linear])] [] in
    let w : World := animate_by 0.5 (set_animator w0 root.entity (animator c LoopMode.loop_once)) in
    match entity_transform w kid.entity {
        Option.some t0 => let t : Transform := t0 in near 0.000001 t.scale.x 2.0,
        Option.none => false
    }

#[test]
def test_animation_is_deterministic : Bool :=
    let o : One := with_animator (animator_crossfade (animator bob LoopMode.loop_ping_pong) slide 0.7) in
    let a : Vec3 := pos (frames o.world 0.013 97) o.entity in
    let b : Vec3 := pos (frames o.world 0.013 97) o.entity in
    a.x == b.x && a.y == b.y && a.z == b.z

// ── Tweens ──────────────────────────────────────────────────────────

#[test]
def test_tween_scales_then_removes_itself : Bool :=
    let s : Spawned := spawn_transform empty_world transform_identity in
    let w0 : World := set_tween s.world s.entity (tween_scale v3_one (vec3 2.0 2.0 2.0) 1.0 Easing.linear) in
    let w1 : World := tween_by 0.25 w0 in
    let w2 : World := tween_by 1.0 w1 in
    let half : Bool := match entity_transform w1 s.entity {
        Option.some t0 => let t : Transform := t0 in near 0.000001 t.scale.y 1.25,
        Option.none => false
    } in
    let done : Bool := match entity_transform w2 s.entity {
        Option.some t0 => let t : Transform := t0 in t.scale.y == 2.0,
        Option.none => false
    } in
    let gone : Bool := match entity_tween w2 s.entity { Option.some _ => false, Option.none => true } in
    half && done && gone

#[test]
def test_a_despawning_tween_removes_the_entity : Bool :=
    let s : Spawned := spawn_transform empty_world transform_identity in
    let w0 : World := set_tween s.world s.entity (tween_then (tween_translation v3_zero v3_one 0.5 Easing.quad_out) TweenEnd.end_despawn) in
    let w1 : World := tween_by 0.3 w0 in
    let w2 : World := tween_by 0.3 w1 in
    entity_exists w1 s.entity && Bool.not (entity_exists w2 s.entity)
