// forge-math: quaternions (x, y, z, w) with w = cos(theta/2), right-handed.
//
// `Copy`: four F64. Rotation uses the standard `v + 2 q_v x (q_v x v + w v)`
// form, which avoids materializing a matrix.

use std::derive {}
use lib::vec {Vec3, vec3, v3_cross, v3_add, v3_scale, v3_normalize, v3_dot}
use lib::num {f64_sin, f64_cos, f64_sqrt, f64_approx_eps}

#[derive Copy Clone Debug]
pub struct Quat {
    x : F64,
    y : F64,
    z : F64,
    w : F64
}

pub def quat (x : F64) (y : F64) (z : F64) (w : F64) : Quat :=
    { x := x, y := y, z := z, w := w : Quat }

pub def quat_identity : Quat := { x := 0.0, y := 0.0, z := 0.0, w := 1.0 : Quat }

pub def quat_conj (q : Quat) : Quat :=
    { x := 0.0 - q.x, y := 0.0 - q.y, z := 0.0 - q.z, w := q.w : Quat }

pub def quat_length_sq (q : Quat) : F64 :=
    q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w

pub def quat_length (q : Quat) : F64 := f64_sqrt (quat_length_sq q)

pub def quat_normalize (q : Quat) : Quat :=
    let inv : F64 := 1.0 / quat_length q in
    { x := q.x * inv, y := q.y * inv, z := q.z * inv, w := q.w * inv : Quat }

/// Hamilton product. `quat_mul a b` applies `b` then `a` to a column vector.
pub def quat_mul (a : Quat) (b : Quat) : Quat :=
    { x := a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
      y := a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
      z := a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
      w := a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
      : Quat }

/// The vector part, as a `Vec3`.
pub def quat_vec (q : Quat) : Vec3 := vec3 q.x q.y q.z

/// Rotate `v` by `q`: `v + 2 q_v x (q_v x v + w v)`.
pub def quat_rotate (q : Quat) (v : Vec3) : Vec3 :=
    let qv : Vec3 := quat_vec q in
    let t : Vec3 := v3_scale (v3_cross qv v) 2.0 in
    v3_add v (v3_add (v3_scale t q.w) (v3_cross qv t))

/// Rotate `v` by the inverse of `q` (for a unit quaternion, the conjugate).
pub def quat_rotate_inv (q : Quat) (v : Vec3) : Vec3 := quat_rotate (quat_conj q) v

/// A rotation of `angle` radians about `axis` (which is normalized here).
pub def quat_from_axis_angle (axis : Vec3) (angle : F64) : Quat :=
    let half : F64 := angle * 0.5 in
    let s : F64 := f64_sin half in
    let a : Vec3 := v3_normalize axis in
    { x := a.x * s, y := a.y * s, z := a.z * s, w := f64_cos half : Quat }

pub def quat_from_z_angle (angle : F64) : Quat :=
    quat_from_axis_angle (vec3 0.0 0.0 1.0) angle

/// Component-wise interpolation. Not a constant-speed path; normalize the
/// result (`quat_slerp` does).
pub def quat_lerp (a : Quat) (b : Quat) (t : F64) : Quat :=
    { x := a.x + (b.x - a.x) * t,
      y := a.y + (b.y - a.y) * t,
      z := a.z + (b.z - a.z) * t,
      w := a.w + (b.w - a.w) * t
      : Quat }

/// Normalized lerp -- a cheap, well-behaved stand-in for true slerp that needs
/// no `acos` (which the toolchain does not ship).
pub def quat_slerp (a : Quat) (b : Quat) (t : F64) : Quat :=
    quat_normalize (quat_lerp a b t)

/// The angle of the rotation, in `[0, 2pi)`.
pub def quat_angle (q : Quat) : F64 := 2.0 * f64_sqrt (1.0 - q.w * q.w)

/// Are two rotations the same rotation? `q` and `-q` are (they act identically),
/// so compare via the squared dot product.
pub def quat_same_rotation (a : Quat) (b : Quat) : Bool :=
    let d : F64 := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w in
    let ad : F64 := let v := d in if v < 0.0 then 0.0 - v else v in
    1.0 - ad < 0.0001

#[test]
def test_quat_identity_rotates_nothing : Bool :=
    let v : Vec3 := vec3 1.0 2.0 3.0 in
    let r : Vec3 := quat_rotate quat_identity v in
    v3_dot r v > 13.9999 && v3_dot r v < 14.0001

#[test]
def test_quat_z90_maps_x_to_y : Bool :=
    let q : Quat := quat_from_z_angle 1.5707963267948966 in
    let r : Vec3 := quat_rotate q (vec3 1.0 0.0 0.0) in
    v3_dot r (vec3 0.0 1.0 0.0) > 0.9999

#[test]
def test_quat_mul_identity : Bool :=
    let q : Quat := quat_from_z_angle 0.7 in
    quat_same_rotation (quat_mul quat_identity q) q

#[test]
def test_quat_inverse_undoes_rotation : Bool :=
    let q : Quat := quat_normalize (quat 0.3 0.5 0.1 0.8) in
    let v : Vec3 := vec3 2.0 0.0 1.0 in
    let back : Vec3 := quat_rotate_inv q (quat_rotate q v) in
    v3_dot back v > 4.9999 && v3_dot back v < 5.0001

#[test]
def test_quat_from_axis_angle_is_unit : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 1.0 1.0 0.0) 1.1 in
    1.0 - quat_length_sq q < 0.0001 && 1.0 - quat_length_sq q > 0.0 - 0.0001

#[test]
def test_quat_angle_of_identity_is_zero : Bool :=
    quat_angle quat_identity < 0.0001

#[test]
def test_quat_rotation_preserves_length : Bool :=
    let q : Quat := quat_normalize (quat 0.2 0.4 0.1 0.9) in
    let v : Vec3 := vec3 1.0 2.0 2.0 in
    let r : Vec3 := quat_rotate q v in
    let lsq : F64 := v3_dot r r in
    lsq > 8.9999 && lsq < 9.0001

#[test]
def test_quat_same_rotation_ignores_sign : Bool :=
    let q : Quat := quat_from_z_angle 0.5 in
    quat_same_rotation q (quat (0.0 - q.x) (0.0 - q.y) (0.0 - q.z) (0.0 - q.w))

/// A spin by a growing clock (`t * speed`, hours in) stays a unit rotation;
/// the old trig reduction made it grow without bound past ~21pi.
#[test]
def test_quat_from_axis_angle_large_angle_is_unit : Bool :=
    f64_approx_eps 0.000001 (quat_length (quat_from_axis_angle (vec3 0.0 1.0 0.0) 135.0)) 1.0
        && f64_approx_eps 0.000001 (quat_length (quat_from_axis_angle (vec3 0.0 1.0 0.0) 54000.0)) 1.0

#[test]
def test_quat_slerp_midpoint : Bool :=
    let a : Quat := quat_identity in
    let b : Quat := quat_from_z_angle 1.5707963267948966 in
    let mid : Quat := quat_slerp a b 0.5 in
    // halfway between 0 and 90deg about z is 45deg
    quat_same_rotation mid (quat_from_z_angle 0.7853981633974483)
