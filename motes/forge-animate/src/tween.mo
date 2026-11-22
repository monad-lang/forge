// forge-animate: tweens. A `Tween` drives one transform property of its
// entity from one value to another over a duration, shaped by an easing:
// game feedback such as a pop, a squash or a slide. One tween per entity
// (a new one replaces the old). When it finishes it stays (holding the end
// value), removes itself, or despawns the entity (a pop that vanishes).
//
// A material tint tween needs per-entity tint overrides in forge-render,
// which do not exist yet; that waits for them.

use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use init::id {Id}
use forge_core::ecs {World, Entity, insert_component, get_component_named, remove_component, despawn}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math::{Vec3, Vec4, Quat, f64_min}
use forge_scene::{transform_name}
use forge_schedule {world_time, time_delta}
use lib::ease {Easing, ease}
use lib::pose {Property, prop_blend, write_prop, v4_of_v3, v4_of_quat}

/// What a finished tween does. `Copy`.
pub type TweenEnd {
    end_hold,
    end_remove,
    end_despawn
}

pub instance Copy TweenEnd {
    def copy (e : TweenEnd) : Pair TweenEnd TweenEnd := Pair.pair e e
}

/// `Copy`.
#[derive Copy Clone Debug]
pub struct Tween {
    prop : Property,
    from : Vec4,
    to : Vec4,
    duration : F64,
    elapsed : F64,
    easing : Easing,
    end : TweenEnd
}

pub def tween (prop : Property) (from : Vec4) (to : Vec4) (duration : F64) (easing : Easing) : Tween :=
    { prop := prop, from := from, to := to, duration := duration, elapsed := 0.0, easing := easing,
      end := TweenEnd.end_remove : Tween }

pub def tween_translation (from : Vec3) (to : Vec3) (duration : F64) (easing : Easing) : Tween :=
    tween Property.prop_translation (v4_of_v3 from) (v4_of_v3 to) duration easing

pub def tween_scale (from : Vec3) (to : Vec3) (duration : F64) (easing : Easing) : Tween :=
    tween Property.prop_scale (v4_of_v3 from) (v4_of_v3 to) duration easing

pub def tween_rotation (from : Quat) (to : Quat) (duration : F64) (easing : Easing) : Tween :=
    tween Property.prop_rotation (v4_of_quat from) (v4_of_quat to) duration easing

/// `t`, ending with `end`.
pub def tween_then (t : Tween) (end : TweenEnd) : Tween := { t with end := end }

/// The value at `elapsed` seconds.
pub def tween_value (t : Tween) (elapsed : F64) : Vec4 :=
    let u : F64 := if t.duration <= 0.0 then 1.0 else f64_min 1.0 (elapsed / t.duration) in
    prop_blend t.prop t.from t.to (ease t.easing u)

pub def tween_done (t : Tween) : Bool := t.elapsed >= t.duration

pub def tween_name : String := "forge.tween"

def as_tween (v : Any) : Tween :=
    match v { Any.any x => let t : Tween := x in t }

/// Start `t` on `e` (replacing any tween it had).
pub def set_tween (world : World) (e : Entity) (t : Tween) : World :=
    insert_component world e tween_name (Any.any t)

pub def entity_tween (world : World) (e : Entity) : Option Tween :=
    match get_component_named world e tween_name {
        Option.some v => Option.some (as_tween v),
        Option.none => Option.none
    }

def finish (world : World) (e : Entity) (t : Tween) : World :=
    match t.end {
        TweenEnd.end_hold => set_tween world e t,
        TweenEnd.end_remove => remove_component world e tween_name,
        TweenEnd.end_despawn => despawn world e
    }

def tween_one (dt : F64) (world : World) (e : Entity) : World :=
    match entity_tween world e {
        Option.some t0 =>
            let t1 : Tween := t0 in
            let t : Tween := { t1 with elapsed := t1.elapsed + dt } in
            let w : World := write_prop world e t.prop (tween_value t t.elapsed) in
            if tween_done t then finish w e t else set_tween w e t,
        Option.none => world
    }

#[terminating]
def tween_all (dt : F64) (world : World) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest => tween_all dt (tween_one dt world e) rest
    }

/// One frame of every tween, by `dt` seconds.
pub def tween_by (dt : F64) (world : World) : World :=
    tween_all dt world (query_entities world [tween_name, transform_name] [])

pub def tween_step (world : World) : World := tween_by (time_delta (world_time world)) world

pub def tween_system : WorldM Id Unit := WorldM.modify tween_step
