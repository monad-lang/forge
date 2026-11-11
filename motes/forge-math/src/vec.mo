// forge-math: Vec2/Vec3/Vec4 as monomorphic `Copy` structs.
//
// Every type derives `Copy Clone` so a formula reads its operands as often as
// it likes (the affine rule), which is the whole reason these are monomorphic
// structs and not a generic `Vec (N : I64)`: a generic type cannot derive or
// hand-write `Copy` (see PLAN.md).
//
// Function names are suffixed (`v3_add`, `v3_dot`, ...) rather than class-based,
// because class dispatch is a RUN-TIME step in this toolchain and a suffix is
// unambiguous at a glance.

use std::derive {}
use lib::num {f64_sqrt, f64_abs}

// ── Vec2 ────────────────────────────────────────────────────────────

#[derive Copy Clone Debug]
pub struct Vec2 {
    x : F64,
    y : F64
}

pub def vec2 (x : F64) (y : F64) : Vec2 := { x := x, y := y : Vec2 }

pub def v2_zero : Vec2 := { x := 0.0, y := 0.0 : Vec2 }

pub def v2_one : Vec2 := { x := 1.0, y := 1.0 : Vec2 }

pub def v2_add (a : Vec2) (b : Vec2) : Vec2 :=
    { x := a.x + b.x, y := a.y + b.y : Vec2 }

pub def v2_sub (a : Vec2) (b : Vec2) : Vec2 :=
    { x := a.x - b.x, y := a.y - b.y : Vec2 }

pub def v2_scale (a : Vec2) (s : F64) : Vec2 :=
    { x := a.x * s, y := a.y * s : Vec2 }

pub def v2_neg (a : Vec2) : Vec2 := { x := 0.0 - a.x, y := 0.0 - a.y : Vec2 }

pub def v2_dot (a : Vec2) (b : Vec2) : F64 := a.x * b.x + a.y * b.y

pub def v2_length_sq (a : Vec2) : F64 := v2_dot a a

pub def v2_length (a : Vec2) : F64 := f64_sqrt (v2_length_sq a)

pub def v2_distance (a : Vec2) (b : Vec2) : F64 := v2_length (v2_sub a b)

/// Unit vector. A zero (or non-finite) input is the caller's responsibility.
pub def v2_normalize (a : Vec2) : Vec2 := v2_scale a (1.0 / v2_length a)

/// The left perpendicular, `(-y, x)`.
pub def v2_perp (a : Vec2) : Vec2 := { x := 0.0 - a.y, y := a.x : Vec2 }

pub def v2_lerp (a : Vec2) (b : Vec2) (t : F64) : Vec2 :=
    { x := a.x + (b.x - a.x) * t, y := a.y + (b.y - a.y) * t : Vec2 }

// ── Vec3 ────────────────────────────────────────────────────────────

#[derive Copy Clone Debug]
pub struct Vec3 {
    x : F64,
    y : F64,
    z : F64
}

pub def vec3 (x : F64) (y : F64) (z : F64) : Vec3 := { x := x, y := y, z := z : Vec3 }

pub def v3_zero : Vec3 := { x := 0.0, y := 0.0, z := 0.0 : Vec3 }

pub def v3_one : Vec3 := { x := 1.0, y := 1.0, z := 1.0 : Vec3 }

pub def v3_up : Vec3 := { x := 0.0, y := 1.0, z := 0.0 : Vec3 }

pub def v3_add (a : Vec3) (b : Vec3) : Vec3 :=
    { x := a.x + b.x, y := a.y + b.y, z := a.z + b.z : Vec3 }

pub def v3_sub (a : Vec3) (b : Vec3) : Vec3 :=
    { x := a.x - b.x, y := a.y - b.y, z := a.z - b.z : Vec3 }

pub def v3_scale (a : Vec3) (s : F64) : Vec3 :=
    { x := a.x * s, y := a.y * s, z := a.z * s : Vec3 }

pub def v3_neg (a : Vec3) : Vec3 :=
    { x := 0.0 - a.x, y := 0.0 - a.y, z := 0.0 - a.z : Vec3 }

pub def v3_dot (a : Vec3) (b : Vec3) : F64 := a.x * b.x + a.y * b.y + a.z * b.z

/// Right-handed cross product.
pub def v3_cross (a : Vec3) (b : Vec3) : Vec3 :=
    { x := a.y * b.z - a.z * b.y,
      y := a.z * b.x - a.x * b.z,
      z := a.x * b.y - a.y * b.x
      : Vec3 }

pub def v3_length_sq (a : Vec3) : F64 := v3_dot a a

pub def v3_length (a : Vec3) : F64 := f64_sqrt (v3_length_sq a)

pub def v3_distance (a : Vec3) (b : Vec3) : F64 := v3_length (v3_sub a b)

pub def v3_normalize (a : Vec3) : Vec3 := v3_scale a (1.0 / v3_length a)

pub def v3_lerp (a : Vec3) (b : Vec3) (t : F64) : Vec3 :=
    { x := a.x + (b.x - a.x) * t,
      y := a.y + (b.y - a.y) * t,
      z := a.z + (b.z - a.z) * t
      : Vec3 }

pub def v3_reflect (v : Vec3) (n : Vec3) : Vec3 :=
    v3_sub v (v3_scale n (2.0 * v3_dot v n))

// ── Vec4 ────────────────────────────────────────────────────────────

#[derive Copy Clone Debug]
pub struct Vec4 {
    x : F64,
    y : F64,
    z : F64,
    w : F64
}

pub def vec4 (x : F64) (y : F64) (z : F64) (w : F64) : Vec4 :=
    { x := x, y := y, z := z, w := w : Vec4 }

pub def v4_zero : Vec4 := { x := 0.0, y := 0.0, z := 0.0, w := 0.0 : Vec4 }

pub def v4_add (a : Vec4) (b : Vec4) : Vec4 :=
    { x := a.x + b.x, y := a.y + b.y, z := a.z + b.z, w := a.w + b.w : Vec4 }

pub def v4_sub (a : Vec4) (b : Vec4) : Vec4 :=
    { x := a.x - b.x, y := a.y - b.y, z := a.z - b.z, w := a.w - b.w : Vec4 }

pub def v4_scale (a : Vec4) (s : F64) : Vec4 :=
    { x := a.x * s, y := a.y * s, z := a.z * s, w := a.w * s : Vec4 }

pub def v4_dot (a : Vec4) (b : Vec4) : F64 :=
    a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w

pub def v4_length_sq (a : Vec4) : F64 := v4_dot a a

pub def v4_length (a : Vec4) : F64 := f64_sqrt (v4_length_sq a)

pub def v4_normalize (a : Vec4) : Vec4 := v4_scale a (1.0 / v4_length a)

/// Drop `w` and renormalize `(x,y,z)` -- the perspective divide, as a value.
pub def v4_to_v3 (a : Vec4) : Vec3 :=
    let inv : F64 := 1.0 / a.w in
    { x := a.x * inv, y := a.y * inv, z := a.z * inv : Vec3 }

#[test]
def test_v2_add : Bool :=
    let s : Vec2 := v2_add (vec2 1.0 2.0) (vec2 0.5 0.25) in
    f64_abs (s.x - 1.5) < 0.0001

#[test]
def test_v2_dot_perp_is_zero : Bool :=
    f64_abs (v2_dot (vec2 3.0 4.0) (v2_perp (vec2 3.0 4.0))) < 0.0001

#[test]
def test_v2_normalize_is_unit : Bool :=
    f64_abs (v2_length (v2_normalize (vec2 3.0 4.0)) - 1.0) < 0.0001

#[test]
def test_v3_add : Bool :=
    let s : Vec3 := v3_add (vec3 1.0 2.0 3.0) (vec3 0.5 0.5 0.5) in
    f64_abs (s.y - 2.5) < 0.0001

#[test]
def test_v3_dot : Bool :=
    f64_abs (v3_dot (vec3 1.0 2.0 3.0) (vec3 1.0 1.0 1.0) - 6.0) < 0.0001

#[test]
def test_v3_cross_x_cross_y_is_z : Bool :=
    let c : Vec3 := v3_cross (vec3 1.0 0.0 0.0) (vec3 0.0 1.0 0.0) in
    f64_abs (c.z - 1.0) < 0.0001

#[test]
def test_v3_cross_is_anticommutative : Bool :=
    let a : Vec3 := vec3 1.0 2.0 3.0 in
    let b : Vec3 := vec3 4.0 5.0 6.0 in
    let ab : Vec3 := v3_cross a b in
    let ba : Vec3 := v3_cross b a in
    f64_abs (ab.x + ba.x) < 0.0001

#[test]
def test_v3_length_345 : Bool := f64_abs (v3_length (vec3 3.0 4.0 0.0) - 5.0) < 0.0001

#[test]
def test_v3_normalize_is_unit : Bool :=
    f64_abs (v3_length (v3_normalize (vec3 2.0 3.0 6.0)) - 1.0) < 0.0001

#[test]
def test_v3_cross_is_perpendicular : Bool :=
    let a : Vec3 := vec3 1.0 2.0 3.0 in
    let b : Vec3 := vec3 4.0 5.0 6.0 in
    let c : Vec3 := v3_cross a b in
    f64_abs (v3_dot a c) < 0.0001 && f64_abs (v3_dot b c) < 0.0001

#[test]
def test_v4_dot : Bool :=
    f64_abs (v4_dot (vec4 1.0 0.0 0.0 0.0) (vec4 0.0 1.0 0.0 0.0)) < 0.0001

#[test]
def test_v4_to_v3_divides_by_w : Bool :=
    let v : Vec3 := v4_to_v3 (vec4 4.0 8.0 12.0 4.0) in
    f64_abs (v.x - 1.0) < 0.0001 && f64_abs (v.z - 3.0) < 0.0001
