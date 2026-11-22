// forge-math: F64 primitives the toolchain does not ship.
//
// `init::number` gives `F64` only `+ - * /` and the comparisons (`F64.add`/
// `sub`/`mul`/`div`/`beq`/`lt`/`gt`, all `#[native]`). There is NO `sqrt`,
// `sin`, `cos`, `abs`, `floor`, and NO integer<->float conversion. Every one of
// those is therefore built here from `+ - * /` and `<`/`>`.
//
// `f64_sqrt` is Newton-Raphson (`g' = (g + x/g)/2`), seeded so it converges
// fast and is EXACT for a perfect square (the toolchain tests assert exact
// values, so it has to be). `f64_sin`/`f64_cos` are a 6/7-term Maclaurin
// series after range reduction to |x| <= pi/2, accurate to ~1e-8 there.

use std::derive {}

pub def f64_pi : F64 := 3.141592653589793
pub def f64_half_pi : F64 := 1.5707963267948966
pub def f64_tau : F64 := 6.283185307179586

/// `|x|`, via the comparison (there is no `F64.abs`).
pub def f64_abs (x : F64) : F64 :=
    if x < 0.0 then 0.0 - x else x

pub def f64_neg (x : F64) : F64 := 0.0 - x

pub def f64_min (a : F64) (b : F64) : F64 := if a < b then a else b

pub def f64_max (a : F64) (b : F64) : F64 := if a > b then a else b

pub def f64_clamp (lo : F64) (hi : F64) (x : F64) : F64 := f64_min hi (f64_max lo x)

/// A small absolute tolerance for comparing computed floats.
pub def f64_epsilon : F64 := 0.0001

pub def f64_approx (a : F64) (b : F64) : Bool := f64_abs (a - b) < f64_epsilon

pub def f64_approx_eps (eps : F64) (a : F64) (b : F64) : Bool := f64_abs (a - b) < eps

/// Newton-Raphson square root: `g' = (g + x/g)/2`. `n` iterations of a
/// quadratic method; the seed chooses which fixed point it falls into.
#[terminating]
def sqrt_go (x : F64) (g : F64) (n : I64) : F64 :=
    if I64.lt 0 n
    then sqrt_go x ((g + x / g) * 0.5) (I64.sub n 1)
    else g

/// Scale `x` by powers of 4 into `[0.25, 4)`, tracking the matching power
/// of 2 for the root. Powers of 2 are exact in binary, so this changes no
/// bits of the result. Bounded: a double's exponent is at most 1023 either
/// way, so 1100 steps cover every finite input.
#[terminating]
def sqrt_scaled (x : F64) (scale : F64) (n : I64) : F64 :=
    if I64.lt 1100 n then scale * sqrt_go x 1.0 8
    else if x >= 4.0 then sqrt_scaled (x * 0.25) (scale * 2.0) (I64.add n 1)
    else if x < 0.25 then sqrt_scaled (x * 4.0) (scale * 0.5) (I64.add n 1)
    else scale * sqrt_go x 1.0 8

/// `sqrt x` (0 for `x <= 0`). The argument is first scaled into
/// `[0.25, 4)`, where Newton from 1.0 reaches full precision in about 6
/// steps; 8 are run. That keeps tiny and huge inputs exact too (seeding
/// Newton far from the root only halves the error per step, so
/// `sqrt 0` used to come out near 6e-8). A perfect square lands exactly.
pub def f64_sqrt (x : F64) : F64 :=
    if x <= 0.0 then 0.0 else sqrt_scaled x 1.0 0

/// The largest `tau * 2^k <= a` (for `a >= tau`). Doubling is exact in
/// binary. Bounded at 1100 doublings, past any finite double's exponent.
#[terminating]
def tau_top (a : F64) (m : F64) (n : I64) : F64 :=
    if I64.lt 1100 n then m
    else if m * 2.0 <= a then tau_top a (m * 2.0) (I64.add n 1)
    else m

/// `a mod tau` for `a >= 0`, by binary long division: subtract `tau * 2^k`
/// from the largest `k` down to 0. O(log a) steps, with no cap on how many
/// turns get removed. The old loop stepped `2pi` at a time and gave up
/// after 20 steps, so `sin` of more than about 21pi radians went through
/// the series with a huge argument and blew up (a spin by elapsed time
/// broke after about 90 s).
#[terminating]
def mod_down (a : F64) (m : F64) (n : I64) : F64 :=
    if I64.lt 1100 n then a
    else if m < f64_tau then a
    else mod_down (if a >= m then a - m else a) (m * 0.5) (I64.add n 1)

/// `x mod 2pi` in `[0, 2pi)` for `x >= 0`.
def mod_tau (a : F64) : F64 :=
    if a < f64_tau then a else mod_down a (tau_top a f64_tau 0) 0

/// `x` wrapped into `[-pi, pi]`: the same angle, for any finite `x`.
/// `sin`/`cos` use it, and so can callers that build angles from a growing
/// clock (`t * speed`) and want to keep them small.
pub def f64_wrap_angle (x : F64) : F64 :=
    let r : F64 := mod_tau (f64_abs x) in
    let w : F64 := if r > f64_pi then r - f64_tau else r in
    if x < 0.0 then 0.0 - w else w

/// Fold `[-pi, pi]` into `[-pi/2, pi/2]` using `sin(pi - x) = sin x`.
def reduce_half (x : F64) : F64 :=
    if x > f64_half_pi then f64_pi - x
    else if x < (0.0 - f64_half_pi) then (0.0 - f64_pi) - x
    else x

/// 7-term Maclaurin `sin` for `|x| <= pi/2` (~1e-8 there). Denominators are
/// the factorial literals `3! 5! ... 13!` so no int->float conversion is
/// needed (there is none in the toolchain).
pub def f64_sin_small (x : F64) : F64 :=
    let x2 : F64 := x * x in
    let x3 : F64 := x * x2 in
    let x5 : F64 := x3 * x2 in
    let x7 : F64 := x5 * x2 in
    let x9 : F64 := x7 * x2 in
    let x11 : F64 := x9 * x2 in
    let x13 : F64 := x11 * x2 in
    x + (0.0 - x3 / 6.0) + x5 / 120.0 + (0.0 - x7 / 5040.0)
        + x9 / 362880.0 + (0.0 - x11 / 39916800.0) + x13 / 6227020800.0

/// 7-term Maclaurin `cos` for `|x| <= pi/2`.
pub def f64_cos_small (x : F64) : F64 :=
    let x2 : F64 := x * x in
    let x4 : F64 := x2 * x2 in
    let x6 : F64 := x4 * x2 in
    let x8 : F64 := x6 * x2 in
    let x10 : F64 := x8 * x2 in
    let x12 : F64 := x10 * x2 in
    1.0 + (0.0 - x2 / 2.0) + x4 / 24.0 + (0.0 - x6 / 720.0)
        + x8 / 40320.0 + (0.0 - x10 / 3628800.0) + x12 / 479001600.0

/// `sin x` for any `x` (reduced, then folded into the series' good range).
pub def f64_sin (x : F64) : F64 := f64_sin_small (reduce_half (f64_wrap_angle x))

/// `cos x = sin(x + pi/2)`.
pub def f64_cos (x : F64) : F64 := f64_sin (x + f64_half_pi)

/// 2^52: at and above it every double is an integer.
def two52 : F64 := 4503599627370496.0

/// `x` rounded to an integer (ties to even), by the 2^52 trick: adding and
/// subtracting 2^52 leaves no bits below the units place. There is no
/// native rounding or float -> int conversion.
pub def f64_round (x : F64) : F64 :=
    if f64_abs x >= two52 then x
    else if x >= 0.0 then (x + two52) - two52
    else (x - two52) + two52

/// The largest integer `<= x`.
pub def f64_floor (x : F64) : F64 :=
    let r : F64 := f64_round x in
    if r > x then r - 1.0 else r

/// `1/x` (a named spelling, so formulas read as reciprocals).
pub def f64_recip (x : F64) : F64 := 1.0 / x

/// `I64 -> F64` by binary expansion. The toolchain has NO integer<->float
/// conversion native, so this builds the float from its bits' place values
/// (exact for every `|n| < 2^53`). O(log n).
#[terminating]
pub def f64_of_i64 (n : I64) : F64 :=
    if I64.lt n 0 then 0.0 - f64_of_i64 (I64.sub 0 n)
    else if I64.beq n 0 then 0.0
    else
        let half : F64 := f64_of_i64 (I64.div n 2) in
        let bit : F64 := if I64.beq (I64.rem n 2) 1 then 1.0 else 0.0 in
        2.0 * half + bit

#[test]
def test_f64_abs_neg : Bool := f64_approx (f64_abs (0.0 - 3.5)) 3.5

#[test]
def test_f64_abs_pos : Bool := f64_approx (f64_abs 3.5) 3.5

#[test]
def test_f64_sqrt_perfect_square : Bool := F64.beq (f64_sqrt 25.0) 5.0

#[test]
def test_f64_sqrt_quarter : Bool := F64.beq (f64_sqrt 0.25) 0.5

#[test]
def test_f64_sqrt_zero_is_exact : Bool := F64.beq (f64_sqrt 0.0) 0.0

#[test]
def test_f64_sqrt_tiny_and_huge : Bool :=
    f64_approx_eps 0.0000000000000001 (f64_sqrt 0.0000000001) 0.00001
        && F64.beq (f64_sqrt 1000000000000.0) 1000000.0

#[test]
def test_f64_sqrt_two : Bool := f64_approx_eps 0.0000001 (f64_sqrt 2.0) 1.4142135623730951

#[test]
def test_f64_sin_zero : Bool := f64_approx (f64_sin 0.0) 0.0

#[test]
def test_f64_sin_half_pi : Bool := f64_approx_eps 0.00001 (f64_sin f64_half_pi) 1.0

#[test]
def test_f64_cos_zero : Bool := f64_approx_eps 0.00001 (f64_cos 0.0) 1.0

#[test]
def test_f64_sin_pi_is_zero : Bool := f64_approx_eps 0.00001 (f64_sin f64_pi) 0.0

#[test]
def test_f64_cos_pi_is_neg_one : Bool := f64_approx_eps 0.00001 (f64_cos f64_pi) (0.0 - 1.0)

#[test]
def test_f64_sin_reduces_large : Bool :=
    // sin(2*pi + pi/2) = 1
    f64_approx_eps 0.00001 (f64_sin (f64_tau + f64_half_pi)) 1.0

#[test]
def test_f64_min_max_clamp : Bool :=
    f64_approx (f64_clamp 0.0 1.0 5.0) 1.0

#[test]
def test_f64_wrap_angle_small_is_identity : Bool :=
    F64.beq (f64_wrap_angle 1.25) 1.25 && F64.beq (f64_wrap_angle (0.0 - 3.0)) (0.0 - 3.0)

#[test]
def test_f64_wrap_angle_many_turns : Bool :=
    f64_approx_eps 0.000001 (f64_wrap_angle (1.0 + f64_tau * 1000.0)) 1.0
        && f64_approx_eps 0.000001 (f64_wrap_angle (0.0 - 1.0 - f64_tau * 1000.0)) (0.0 - 1.0)
        && f64_approx_eps 0.000001 (f64_wrap_angle (f64_pi + 0.5 + f64_tau * 77.0)) (0.5 - f64_pi)

def unit_circle_at (x : F64) : Bool :=
    let s : F64 := f64_sin x in
    let c : F64 := f64_cos x in
    f64_approx_eps 0.000001 (s * s + c * c) 1.0 && s <= 1.000001 && s >= 0.0 - 1.000001

/// Past 21pi the old reduction gave up; `sin^2 + cos^2` stays 1 far beyond.
#[test]
def test_f64_sin_cos_large_arguments : Bool :=
    let ok : F64 -> Bool := unit_circle_at in
    ok 100.0 && ok 1000.0 && ok 123456.789 && ok 1000000.0 && ok (0.0 - 1000000.0)

/// `sin` many turns out matches `sin` of the reduced angle.
#[test]
def test_f64_sin_periodic_far_out : Bool :=
    f64_approx_eps 0.00001 (f64_sin (0.7 + f64_tau * 5000.0)) (f64_sin 0.7)
        && f64_approx_eps 0.00001 (f64_cos (0.0 - 2.0 - f64_tau * 300.0)) (f64_cos 2.0)

#[test]
def test_f64_floor : Bool :=
    F64.beq (f64_floor 2.5) 2.0 && F64.beq (f64_floor (0.0 - 2.5)) (0.0 - 3.0) && F64.beq (f64_floor 3.0) 3.0
        && F64.beq (f64_floor (0.0 - 0.25)) (0.0 - 1.0) && F64.beq (f64_floor 0.75) 0.0
        && F64.beq (f64_floor 10000000000.5) 10000000000.0 && F64.beq (f64_floor (0.0 - 7.0)) (0.0 - 7.0)

#[test]
def test_f64_round_ties_to_even : Bool :=
    F64.beq (f64_round 2.5) 2.0 && F64.beq (f64_round 3.5) 4.0 && F64.beq (f64_round (0.0 - 1.4)) (0.0 - 1.0)

#[test]
def test_f64_of_i64 : Bool :=
    F64.beq (f64_of_i64 0) 0.0 && F64.beq (f64_of_i64 1) 1.0 && F64.beq (f64_of_i64 37) 37.0
        && F64.beq (f64_of_i64 1024) 1024.0 && F64.beq (f64_of_i64 (I64.sub 0 6)) (0.0 - 6.0)
