// forge-animate: easing curves. Each is a pure `F64 -> F64` on [0, 1] that
// is EXACT at both ends (0 -> 0, 1 -> 1); inputs outside [0, 1] are
// clamped. `back` overshoots and `bounce` rebounds in between; the rest are
// monotone.

use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use forge_math::{f64_sin, f64_cos, f64_half_pi, f64_pi}

/// An easing curve. `Copy`.
pub type Easing {
    linear,
    quad_in, quad_out, quad_in_out,
    cubic_in, cubic_out, cubic_in_out,
    quart_in, quart_out, quart_in_out,
    sine_in, sine_out, sine_in_out,
    back_in, back_out,
    bounce_out,
    step
}

pub instance Copy Easing {
    def copy (e : Easing) : Pair Easing Easing := Pair.pair e e
}

def back_c1 : F64 := 1.70158

def back_c3 : F64 := 2.70158

def bounce (t : F64) : F64 :=
    let n : F64 := 7.5625 in
    let d : F64 := 2.75 in
    if t < 1.0 / d then n * t * t
    else if t < 2.0 / d then let u : F64 := t - 1.5 / d in n * u * u + 0.75
    else if t < 2.5 / d then let u : F64 := t - 2.25 / d in n * u * u + 0.9375
    else let u : F64 := t - 2.625 / d in n * u * u + 0.984375

def pow2 (x : F64) : F64 := x * x

def pow3 (x : F64) : F64 := x * x * x

def pow4 (x : F64) : F64 := pow2 (pow2 x)

/// The curve on the open interval (the ends are handled by `ease`).
def curve (e : Easing) (t : F64) : F64 :=
    let u : F64 := 1.0 - t in
    match e {
        Easing.linear => t,
        Easing.quad_in => pow2 t,
        Easing.quad_out => 1.0 - pow2 u,
        Easing.quad_in_out => if t < 0.5 then 2.0 * pow2 t else 1.0 - pow2 (2.0 - 2.0 * t) * 0.5,
        Easing.cubic_in => pow3 t,
        Easing.cubic_out => 1.0 - pow3 u,
        Easing.cubic_in_out => if t < 0.5 then 4.0 * pow3 t else 1.0 - pow3 (2.0 - 2.0 * t) * 0.5,
        Easing.quart_in => pow4 t,
        Easing.quart_out => 1.0 - pow4 u,
        Easing.quart_in_out => if t < 0.5 then 8.0 * pow4 t else 1.0 - pow4 (2.0 - 2.0 * t) * 0.5,
        Easing.sine_in => 1.0 - f64_cos (t * f64_half_pi),
        Easing.sine_out => f64_sin (t * f64_half_pi),
        Easing.sine_in_out => (1.0 - f64_cos (t * f64_pi)) * 0.5,
        Easing.back_in => back_c3 * pow3 t - back_c1 * pow2 t,
        Easing.back_out => 1.0 - (back_c3 * pow3 u - back_c1 * pow2 u),
        Easing.bounce_out => bounce t,
        Easing.step => 0.0
    }

/// `e` at `t`, with `t` clamped to [0, 1]; exactly 0 at 0 and 1 at 1.
pub def ease (e : Easing) (t : F64) : F64 :=
    if t <= 0.0 then 0.0 else if t >= 1.0 then 1.0 else curve e t

// ── Tests ───────────────────────────────────────────────────────────

def all_easings : List Easing :=
    [ Easing.linear, Easing.quad_in, Easing.quad_out, Easing.quad_in_out, Easing.cubic_in,
      Easing.cubic_out, Easing.cubic_in_out, Easing.quart_in, Easing.quart_out, Easing.quart_in_out,
      Easing.sine_in, Easing.sine_out, Easing.sine_in_out, Easing.back_in, Easing.back_out,
      Easing.bounce_out, Easing.step ]

def monotone_easings : List Easing :=
    [ Easing.linear, Easing.quad_in, Easing.quad_out, Easing.quad_in_out, Easing.cubic_in,
      Easing.cubic_out, Easing.cubic_in_out, Easing.quart_in, Easing.quart_out, Easing.quart_in_out,
      Easing.sine_in, Easing.sine_out, Easing.sine_in_out, Easing.step ]

#[terminating]
def ends_exact (es : List Easing) : Bool :=
    match es {
        List.empty => true,
        List.cons e rest => ease e 0.0 == 0.0 && ease e 1.0 == 1.0 && ease e (0.0 - 3.0) == 0.0
                                && ease e 7.0 == 1.0 && ends_exact rest
    }

#[terminating]
def rising (e : Easing) (t : F64) (prev : F64) : Bool :=
    if t > 1.0 then true
    else
        let v : F64 := ease e t in
        if v + 0.0000001 < prev then false else rising e (t + 0.01) v

#[terminating]
def all_rising (es : List Easing) : Bool :=
    match es {
        List.empty => true,
        List.cons e rest => rising e 0.0 0.0 && all_rising rest
    }

/// The in-out curves are continuous at the midpoint.
def mid_continuous (e : Easing) : Bool :=
    let a : F64 := ease e 0.4999999 in
    let b : F64 := ease e 0.5000001 in
    (b - a) < 0.0001 && (a - b) < 0.0001

#[test]
def test_every_easing_is_exact_at_the_ends : Bool := ends_exact all_easings

#[test]
def test_the_monotone_easings_never_go_back : Bool := all_rising monotone_easings

#[test]
def test_in_out_curves_meet_at_the_middle : Bool :=
    mid_continuous Easing.quad_in_out && mid_continuous Easing.cubic_in_out
        && mid_continuous Easing.quart_in_out && mid_continuous Easing.sine_in_out

#[test]
def test_back_overshoots_and_bounce_rebounds : Bool :=
    ease Easing.back_in 0.2 < 0.0 && ease Easing.back_out 0.8 > 1.0 && ease Easing.bounce_out 0.5 > 0.7
