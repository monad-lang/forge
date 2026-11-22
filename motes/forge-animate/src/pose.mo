// forge-animate: the transform properties an animation drives, and how a
// value of each is read, written and blended.
//
// Every animated value travels as a `Vec4`, so one track type and one
// tween type cover them all: translation and scale use `xyz`, a rotation
// is a quaternion `xyzw`, a scalar is `x`. Rotations blend by normalized
// lerp along the shorter arc (forge-math's `quat_slerp` is the same nlerp;
// there is no `acos` for a true slerp).

use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {World, Entity, insert_component}
use forge_math::{Vec3, vec3, Vec4, vec4, v4_dot, v4_scale, v4_normalize, Quat, quat}
use forge_scene::{Transform, transform_new, transform_name, entity_transform}

/// A transform property. `Copy`.
pub type Property {
    prop_translation,
    prop_rotation,
    prop_scale
}

pub instance Copy Property {
    def copy (p : Property) : Pair Property Property := Pair.pair p p
}

pub def v4_of_v3 (v : Vec3) : Vec4 := vec4 v.x v.y v.z 0.0

pub def v4_of_quat (q : Quat) : Vec4 := vec4 q.x q.y q.z q.w

pub def v3_of_v4 (v : Vec4) : Vec3 := vec3 v.x v.y v.z

pub def quat_of_v4 (v : Vec4) : Quat := quat v.x v.y v.z v.w

/// Componentwise `a + (b - a) * t`.
pub def v4_lerp (a : Vec4) (b : Vec4) (t : F64) : Vec4 :=
    vec4 (a.x + (b.x - a.x) * t) (a.y + (b.y - a.y) * t) (a.z + (b.z - a.z) * t) (a.w + (b.w - a.w) * t)

/// Quaternions as `Vec4`: the shorter arc (flip `b` when the dot product is
/// negative), lerped, normalized.
pub def v4_nlerp_short (a : Vec4) (b : Vec4) (t : F64) : Vec4 :=
    let b1 : Vec4 := if v4_dot a b < 0.0 then v4_scale b (0.0 - 1.0) else b in
    v4_normalize (v4_lerp a b1 t)

/// Blend two values of `p` by `t`.
pub def prop_blend (p : Property) (a : Vec4) (b : Vec4) (t : F64) : Vec4 :=
    match p {
        Property.prop_rotation => v4_nlerp_short a b t,
        Property.prop_translation => v4_lerp a b t,
        Property.prop_scale => v4_lerp a b t
    }

pub def prop_is_rotation (p : Property) : Bool :=
    match p {
        Property.prop_rotation => true,
        Property.prop_translation => false,
        Property.prop_scale => false
    }

/// `p` of a transform.
pub def prop_get (p : Property) (t : Transform) : Vec4 :=
    match p {
        Property.prop_translation => v4_of_v3 t.translation,
        Property.prop_rotation => v4_of_quat t.rotation,
        Property.prop_scale => v4_of_v3 t.scale
    }

/// A transform with `p` replaced by `v`.
pub def prop_set (p : Property) (t : Transform) (v : Vec4) : Transform :=
    match p {
        Property.prop_translation => transform_new (v3_of_v4 v) t.rotation t.scale,
        Property.prop_rotation => transform_new t.translation (quat_of_v4 v) t.scale,
        Property.prop_scale => transform_new t.translation t.rotation (v3_of_v4 v)
    }

/// `e`'s current `p`, if it has a transform.
pub def read_prop (world : World) (e : Entity) (p : Property) : Option Vec4 :=
    match entity_transform world e {
        Option.some t0 => let t : Transform := t0 in Option.some (prop_get p t),
        Option.none => Option.none
    }

/// Write `v` as `e`'s `p` (no-op without a transform).
pub def write_prop (world : World) (e : Entity) (p : Property) (v : Vec4) : World :=
    match entity_transform world e {
        Option.some t0 => let t : Transform := t0 in insert_component world e transform_name (Any.any (prop_set p t v)),
        Option.none => world
    }

/// Blend `e`'s current `p` toward `v` by weight `w` (1 overwrites).
pub def blend_prop (world : World) (e : Entity) (p : Property) (v : Vec4) (w : F64) : World :=
    match entity_transform world e {
        Option.some t0 =>
            let t : Transform := t0 in
            let now : Vec4 := prop_get p t in
            insert_component world e transform_name (Any.any (prop_set p t (prop_blend p now v w))),
        Option.none => world
    }
