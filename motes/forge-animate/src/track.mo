// forge-animate: keyframe tracks.
//
// A `Track` is a list of keys `(time, value, easing)` in time order. The
// value at time `t` interpolates between the keys around it, shaped by the
// LATER key's easing (the easing says how the segment arriving at that key
// moves). Before the first key it holds the first value, after the last it
// holds the last.
//
// Sampling is one pass over the keys: `List` is affine here (each list is
// walked once), and a track has a handful of keys. A binary search needs
// an indexed persistent vector; that is a later optimisation, not a
// semantic change.

use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use forge_math::{Vec3, Vec4, vec4, v4_zero, Quat}
use lib::ease {Easing, ease}
use lib::pose {Property, prop_blend, v4_of_v3, v4_of_quat, v3_of_v4, quat_of_v4}

/// One key. `Copy`.
#[derive Copy Clone Debug]
pub struct Key {
    time : F64,
    value : Vec4,
    easing : Easing
}

pub def key (time : F64) (value : Vec4) (easing : Easing) : Key :=
    { time := time, value := value, easing := easing : Key }

pub def key_f64 (time : F64) (x : F64) (easing : Easing) : Key := key time (vec4 x 0.0 0.0 0.0) easing

pub def key_vec3 (time : F64) (v : Vec3) (easing : Easing) : Key := key time (v4_of_v3 v) easing

pub def key_quat (time : F64) (q : Quat) (easing : Easing) : Key := key time (v4_of_quat q) easing

pub def key_time (k : Key) : F64 := k.time

/// Keys for one property, in time order. `Copy` (identity: a persistent list).
pub struct Track {
    prop : Property,
    keys : List Key
}

pub instance Copy Track {
    def copy (t : Track) : Pair Track Track := Pair.pair t t
}

/// A track for `prop`. `keys` must be in time order.
pub def track (prop : Property) (keys : List Key) : Track := { prop := prop, keys := keys : Track }

pub def track_prop (t : Track) : Property := t.prop

#[terminating]
def last_time (ks : List Key) (acc : F64) : F64 :=
    match ks {
        List.empty => acc,
        List.cons k rest => last_time rest k.time
    }

/// The time of the last key (0 for an empty track).
pub def track_duration (t : Track) : F64 := last_time t.keys 0.0

def between (p : Property) (a : Key) (b : Key) (t : F64) : Vec4 :=
    let span : F64 := b.time - a.time in
    if span <= 0.0 then b.value
    else prop_blend p a.value b.value (ease b.easing ((t - a.time) / span))

#[terminating]
def sample_go (p : Property) (ks : List Key) (prev : Option Key) (t : F64) : Vec4 :=
    match ks {
        List.empty =>
            match prev {
                Option.some a => a.value,
                Option.none => v4_zero
            },
        List.cons k rest =>
            if t < k.time
            then
                match prev {
                    Option.some a => between p a k t,
                    Option.none => k.value
                }
            else sample_go p rest (Option.some k) t
    }

/// The track's value at `t`.
pub def track_sample (tr : Track) (t : F64) : Vec4 := sample_go tr.prop tr.keys Option.none t

pub def track_f64_at (tr : Track) (t : F64) : F64 :=
    let v : Vec4 := track_sample tr t in
    v.x

pub def track_vec3_at (tr : Track) (t : F64) : Vec3 := v3_of_v4 (track_sample tr t)

pub def track_quat_at (tr : Track) (t : F64) : Quat := quat_of_v4 (track_sample tr t)
