// The touch stick's pure math, native so it can be tested (web.mo is
// web-only). The coordinates are stick-local CSS pixels: the CSS gives
// `.knob` `pointer-events: none` so the stick itself is always the event
// target, and its 156px box puts the centre at `(stick_radius,
// stick_radius)`. The knob's transform is clamped by `knob_of`.

use std::list {}
use forge_math {f64_abs, f64_sqrt}

/// The stick's radius in CSS pixels (its box is 156x156; see `forge_css`).
pub def stick_radius : F64 := 78.0

/// Dead zone, as a fraction of the radius: a thumb has to move this far
/// before any direction engages (0.25 was too twitchy in play).
pub def stick_dead : F64 := 0.4

/// Half the diagonal cone (22.5 degrees): a drag this side of an axis
/// counts toward it, so eight directions come out of a round stick.
pub def stick_cone : F64 := 0.41421356

pub def stick_len (x : F64) (y : F64) : F64 := f64_sqrt (x * x + y * y)

/// The direction keys `(dx, dy)` (from the stick's centre) asks for, as
/// four booleans (W, S, A, D). Past the dead zone, the dominant axis wins
/// inside its cone; a diagonal engages both.
pub def stick_dirs (x : F64) (y : F64) : List Bool :=
    let len : F64 := stick_len x y in
    if len < stick_radius * stick_dead then [false, false, false, false]
    else
        let ax : F64 := f64_abs x in
        let ay : F64 := f64_abs y in
        let wide : Bool := ay >= ax * stick_cone in
        let tall : Bool := ax >= ay * stick_cone in
        [ y < 0.0 && wide, y > 0.0 && wide, x < 0.0 && tall, x > 0.0 && tall ]

/// The knob offset for the drawn position, clamped to the stick.
pub def knob_of (x : F64) (y : F64) : Pair F64 F64 :=
    let len : F64 := stick_len x y in
    if len > stick_radius && len > 0.0
    then Pair.pair (x * stick_radius / len) (y * stick_radius / len)
    else Pair.pair x y

// ── Tests ───────────────────────────────────────────────────────────
//
// `stick_dirs`/`knob_of` take offsets from the stick CENTRE, which is what
// `stick_model` computes as `(offset_x - stick_radius, offset_y -
// stick_radius)`. A raw DOM offset of `(78,78)` is therefore `(0,0)` here.

/// The centre must be neutral. This is the regression: when the knob was the
/// event target, its centre reached `stick_model` as `(-46,-46)` and engaged
/// W+A.
#[test]
def test_centre_is_neutral : Bool :=
    stick_dirs 0.0 0.0 == [false, false, false, false]

#[test]
def test_inside_the_dead_zone_is_neutral : Bool :=
    stick_dirs 20.0 0.0 == [false, false, false, false]

#[test]
def test_right_is_d : Bool :=
    stick_dirs 60.0 0.0 == [false, false, false, true]

#[test]
def test_up_is_w : Bool :=
    stick_dirs 0.0 (0.0 - 60.0) == [true, false, false, false]

#[test]
def test_down_right_is_both : Bool :=
    stick_dirs 50.0 50.0 == [false, true, false, true]

#[test]
def test_up_left_is_both : Bool :=
    stick_dirs (0.0 - 50.0) (0.0 - 50.0) == [true, false, true, false]

#[test]
def test_knob_is_clamped : Bool :=
    match knob_of 200.0 0.0 {
        Pair.pair kx ky => f64_abs (kx - stick_radius) < 0.001 && f64_abs ky < 0.001
    }

#[test]
def test_knob_passes_through_inside : Bool :=
    match knob_of 12.0 (0.0 - 7.0) {
        Pair.pair kx ky => f64_abs (kx - 12.0) < 0.001 && f64_abs (ky + 7.0) < 0.001
    }
