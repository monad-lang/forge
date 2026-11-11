// forge-math: Mat3/Mat4, stored as COLUMNS of `VecN` (so `Mat4` is four
// `Vec4` columns, `m * v` is a weighted sum of columns, and the storage order
// is the column-major one a GPU wants). `Copy`: nested `Vec`s are `Copy`.
//
// Right-handed, depth to `[-1, 1]` (the OpenGL convention) -- this is the one
// convention the whole renderer will assume, so it is stated once, here.

use std::derive {}
use lib::vec {
    Vec3, vec3, v3_add, v3_dot, v3_cross, v3_scale, v3_normalize, v3_sub,
    Vec4, vec4, v4_add, v4_scale
}
use lib::quat {Quat, quat_from_axis_angle}
use lib::num {f64_sin, f64_cos}

// ── Mat3 ────────────────────────────────────────────────────────────

#[derive Copy Clone Debug]
pub struct Mat3 {
    cx : Vec3,
    cy : Vec3,
    cz : Vec3
}

pub def mat3 (cx : Vec3) (cy : Vec3) (cz : Vec3) : Mat3 := { cx := cx, cy := cy, cz := cz : Mat3 }

pub def mat3_identity : Mat3 :=
    { cx := vec3 1.0 0.0 0.0, cy := vec3 0.0 1.0 0.0, cz := vec3 0.0 0.0 1.0 : Mat3 }

pub def mat3_col_x (m : Mat3) : Vec3 := m.cx

pub def mat3_col_y (m : Mat3) : Vec3 := m.cy

pub def mat3_col_z (m : Mat3) : Vec3 := m.cz

/// `m * v`: a weighted sum of the columns.
pub def mat3_mul_vec3 (m : Mat3) (v : Vec3) : Vec3 :=
    let a : Vec3 := v3_scale m.cx v.x in
    let b : Vec3 := v3_scale m.cy v.y in
    let c : Vec3 := v3_scale m.cz v.z in
    v3_add (v3_add a b) c

/// Matrix product: each column of `b` transformed by `a`.
pub def mat3_mul (a : Mat3) (b : Mat3) : Mat3 :=
    { cx := mat3_mul_vec3 a b.cx,
      cy := mat3_mul_vec3 a b.cy,
      cz := mat3_mul_vec3 a b.cz
      : Mat3 }

pub def mat3_transpose (m : Mat3) : Mat3 :=
    { cx := vec3 m.cx.x m.cy.x m.cz.x,
      cy := vec3 m.cx.y m.cy.y m.cz.y,
      cz := vec3 m.cx.z m.cy.z m.cz.z
      : Mat3 }

/// The upper-left 3x3 of a `Mat4`, dropping translation.
pub def mat4_to_mat3 (m : Mat4) : Mat3 :=
    { cx := vec3 m.cx.x m.cx.y m.cx.z,
      cy := vec3 m.cy.x m.cy.y m.cy.z,
      cz := vec3 m.cz.x m.cz.y m.cz.z
      : Mat3 }

// ── Mat4 ────────────────────────────────────────────────────────────

#[derive Copy Clone Debug]
pub struct Mat4 {
    cx : Vec4,
    cy : Vec4,
    cz : Vec4,
    cw : Vec4
}

pub def mat4 (cx : Vec4) (cy : Vec4) (cz : Vec4) (cw : Vec4) : Mat4 :=
    { cx := cx, cy := cy, cz := cz, cw := cw : Mat4 }

pub def mat4_col_x (m : Mat4) : Vec4 := m.cx

pub def mat4_col_y (m : Mat4) : Vec4 := m.cy

pub def mat4_col_z (m : Mat4) : Vec4 := m.cz

pub def mat4_col_w (m : Mat4) : Vec4 := m.cw

/// The translation column of an affine transform.
pub def mat4_translation (m : Mat4) : Vec3 := vec3 m.cw.x m.cw.y m.cw.z

pub def mat4_identity : Mat4 :=
    { cx := vec4 1.0 0.0 0.0 0.0,
      cy := vec4 0.0 1.0 0.0 0.0,
      cz := vec4 0.0 0.0 1.0 0.0,
      cw := vec4 0.0 0.0 0.0 1.0
      : Mat4 }

pub def mat4_mul_vec4 (m : Mat4) (v : Vec4) : Vec4 :=
    let a : Vec4 := v4_scale m.cx v.x in
    let b : Vec4 := v4_scale m.cy v.y in
    let c : Vec4 := v4_scale m.cz v.z in
    let d : Vec4 := v4_scale m.cw v.w in
    v4_add (v4_add a b) (v4_add c d)

pub def mat4_mul (a : Mat4) (b : Mat4) : Mat4 :=
    { cx := mat4_mul_vec4 a b.cx,
      cy := mat4_mul_vec4 a b.cy,
      cz := mat4_mul_vec4 a b.cz,
      cw := mat4_mul_vec4 a b.cw
      : Mat4 }

/// Transform a POINT (`w = 1`), returning the `(x,y,z)` sum of the first three
/// components -- no perspective divide (use `mat4_mul_vec4` for that).
pub def mat4_transform_point (m : Mat4) (p : Vec3) : Vec3 :=
    vec3 (m.cx.x * p.x + m.cy.x * p.y + m.cz.x * p.z + m.cw.x)
         (m.cx.y * p.x + m.cy.y * p.y + m.cz.y * p.z + m.cw.y)
         (m.cx.z * p.x + m.cy.z * p.y + m.cz.z * p.z + m.cw.z)

/// Transform a DIRECTION (`w = 0`), ignoring translation.
pub def mat4_transform_dir (m : Mat4) (d : Vec3) : Vec3 :=
    vec3 (m.cx.x * d.x + m.cy.x * d.y + m.cz.x * d.z)
         (m.cx.y * d.x + m.cy.y * d.y + m.cz.y * d.z)
         (m.cx.z * d.x + m.cy.z * d.y + m.cz.z * d.z)

pub def mat4_translate (t : Vec3) : Mat4 :=
    { cx := vec4 1.0 0.0 0.0 0.0,
      cy := vec4 0.0 1.0 0.0 0.0,
      cz := vec4 0.0 0.0 1.0 0.0,
      cw := vec4 t.x t.y t.z 1.0
      : Mat4 }

pub def mat4_scale (s : Vec3) : Mat4 :=
    { cx := vec4 s.x 0.0 0.0 0.0,
      cy := vec4 0.0 s.y 0.0 0.0,
      cz := vec4 0.0 0.0 s.z 0.0,
      cw := vec4 0.0 0.0 0.0 1.0
      : Mat4 }

pub def mat4_uniform_scale (s : F64) : Mat4 := mat4_scale (vec3 s s s)

/// Rotation matrix for a unit quaternion (row-major formula, written as
/// columns).
pub def mat4_from_quat (q : Quat) : Mat4 :=
    let x : F64 := q.x in
    let y : F64 := q.y in
    let z : F64 := q.z in
    let w : F64 := q.w in
    let xx : F64 := x * x in
    let yy : F64 := y * y in
    let zz : F64 := z * z in
    let xy : F64 := x * y in
    let xz : F64 := x * z in
    let yz : F64 := y * z in
    let xw : F64 := x * w in
    let yw : F64 := y * w in
    let zw : F64 := z * w in
    { cx := vec4 (1.0 - 2.0 * (yy + zz)) (2.0 * (xy + zw)) (2.0 * (xz - yw)) 0.0,
      cy := vec4 (2.0 * (xy - zw)) (1.0 - 2.0 * (xx + zz)) (2.0 * (yz + xw)) 0.0,
      cz := vec4 (2.0 * (xz + yw)) (2.0 * (yz - xw)) (1.0 - 2.0 * (xx + yy)) 0.0,
      cw := vec4 0.0 0.0 0.0 1.0
      : Mat4 }

pub def mat4_rotate_axis_angle (axis : Vec3) (angle : F64) : Mat4 :=
    mat4_from_quat (quat_from_axis_angle axis angle)

/// `T * R * S` -- the usual model matrix.
pub def mat4_trs (t : Vec3) (q : Quat) (s : Vec3) : Mat4 :=
    mat4_mul (mat4_translate t) (mat4_mul (mat4_from_quat q) (mat4_scale s))

pub def mat4_transpose (m : Mat4) : Mat4 :=
    { cx := vec4 m.cx.x m.cy.x m.cz.x m.cw.x,
      cy := vec4 m.cx.y m.cy.y m.cz.y m.cw.y,
      cz := vec4 m.cx.z m.cy.z m.cz.z m.cw.z,
      cw := vec4 m.cx.w m.cy.w m.cz.w m.cw.w
      : Mat4 }

/// Right-handed perspective, mapping the view frustum to `[-1,1]^3`.
/// `fovy` is in radians. `tan(fovy/2)` is `sin/cos` (there is no `F64.tan`).
pub def mat4_perspective (fovy : F64) (aspect : F64) (near : F64) (far : F64) : Mat4 :=
    let f : F64 := f64_cos (fovy * 0.5) / f64_sin (fovy * 0.5) in
    let d : F64 := near - far in
    { cx := vec4 (f / aspect) 0.0 0.0 0.0,
      cy := vec4 0.0 f 0.0 0.0,
      cz := vec4 0.0 0.0 ((far + near) / d) (0.0 - 1.0),
      cw := vec4 0.0 0.0 ((2.0 * far * near) / d) 0.0
      : Mat4 }

/// Right-handed orthographic projection.
pub def mat4_orthographic
    (left : F64) (right : F64) (bottom : F64) (top : F64) (near : F64) (far : F64)
    : Mat4 :=
    let rl : F64 := right - left in
    let tb : F64 := top - bottom in
    let fn_ : F64 := far - near in
    { cx := vec4 (2.0 / rl) 0.0 0.0 0.0,
      cy := vec4 0.0 (2.0 / tb) 0.0 0.0,
      cz := vec4 0.0 0.0 (0.0 - (2.0 / fn_)) 0.0,
      cw := vec4 (0.0 - ((right + left) / rl))
                 (0.0 - ((top + bottom) / tb))
                 (0.0 - ((far + near) / fn_))
                 1.0
      : Mat4 }

/// Right-handed view matrix looking from `eye` at `center`, `up` as the hint.
pub def mat4_look_at (eye : Vec3) (center : Vec3) (up : Vec3) : Mat4 :=
    let f : Vec3 := v3_normalize (v3_sub center eye) in
    let s : Vec3 := v3_normalize (v3_cross f up) in
    let u : Vec3 := v3_cross s f in
    { cx := vec4 s.x u.x (0.0 - f.x) 0.0,
      cy := vec4 s.y u.y (0.0 - f.y) 0.0,
      cz := vec4 s.z u.z (0.0 - f.z) 0.0,
      cw := vec4 (0.0 - v3_dot s eye) (0.0 - v3_dot u eye) (v3_dot f eye) 1.0
      : Mat4 }

#[test]
def test_mat3_identity_is_unit : Bool :=
    let v : Vec3 := vec3 1.0 2.0 3.0 in
    let r : Vec3 := mat3_mul_vec3 mat3_identity v in
    v3_dot r v > 13.9999 && v3_dot r v < 14.0001

#[test]
def test_mat3_mul_identity : Bool :=
    let m : Mat3 := mat3 (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0) (vec3 7.0 8.0 9.0) in
    let p : Mat3 := mat3_mul m mat3_identity in
    v3_dot p.cx m.cx > 13.9999 && v3_dot p.cz m.cz > 193.9999 && v3_dot p.cz m.cz < 194.0001

#[test]
def test_mat3_transpose_twice_is_identity : Bool :=
    let m : Mat3 := mat3 (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0) (vec3 7.0 8.0 9.0) in
    let t : Mat3 := mat3_transpose (mat3_transpose m) in
    v3_dot t.cx m.cx > 13.9999 && v3_dot t.cy m.cy > 76.9999

#[test]
def test_mat4_identity_is_unit : Bool :=
    let p : Vec3 := mat4_transform_point mat4_identity (vec3 4.0 5.0 6.0) in
    v3_dot p (vec3 4.0 5.0 6.0) > 76.9999 && v3_dot p (vec3 4.0 5.0 6.0) < 77.0001

#[test]
def test_mat4_translate_moves_point : Bool :=
    let p : Vec3 := mat4_transform_point (mat4_translate (vec3 10.0 20.0 30.0)) (vec3 1.0 0.0 0.0) in
    v3_dot p (vec3 11.0 20.0 30.0) > 0.5

#[test]
def test_mat4_translate_ignores_direction : Bool :=
    let d : Vec3 := mat4_transform_dir (mat4_translate (vec3 10.0 20.0 30.0)) (vec3 1.0 0.0 0.0) in
    v3_dot d (vec3 1.0 0.0 0.0) > 0.9999

#[test]
def test_mat4_scale : Bool :=
    let p : Vec3 := mat4_transform_point (mat4_scale (vec3 2.0 3.0 4.0)) (vec3 1.0 1.0 1.0) in
    v3_dot p (vec3 2.0 3.0 4.0) > 28.9999

#[test]
def test_mat4_mul_identity : Bool :=
    let m : Mat4 := mat4_trs (vec3 1.0 2.0 3.0) (quat_from_axis_angle (vec3 0.0 1.0 0.0) 0.6) (vec3 2.0 2.0 2.0) in
    let r : Mat4 := mat4_mul m mat4_identity in
    let p : Vec3 := mat4_transform_point r (vec3 1.0 0.0 0.0) in
    let q : Vec3 := mat4_transform_point m (vec3 1.0 0.0 0.0) in
    v3_dot (v3_sub p q) (v3_sub p q) < 0.0001

#[test]
def test_mat4_rotation_from_quat_z90 : Bool :=
    let m : Mat4 := mat4_rotate_axis_angle (vec3 0.0 0.0 1.0) 1.5707963267948966 in
    let r : Vec3 := mat4_transform_dir m (vec3 1.0 0.0 0.0) in
    v3_dot r (vec3 0.0 1.0 0.0) > 0.9999

#[test]
def test_mat4_transpose_twice : Bool :=
    let m : Mat4 := mat4_translate (vec3 1.0 2.0 3.0) in
    let t : Mat4 := mat4_transpose (mat4_transpose m) in
    let p : Vec3 := mat4_transform_point t (vec3 0.0 0.0 0.0) in
    v3_dot p (vec3 1.0 2.0 3.0) > 13.9999 && v3_dot p (vec3 1.0 2.0 3.0) < 14.0001

#[test]
def test_mat4_perspective_maps_near_to_minus_one : Bool :=
    // A point on the near plane at the center of the view goes to z = -1.
    let m : Mat4 := mat4_perspective 1.5 1.5 1.0 100.0 in
    let clip : Vec4 := mat4_mul_vec4 m (vec4 0.0 0.0 (0.0 - 1.0) 1.0) in
    let ndc_z : F64 := clip.z / clip.w in
    let d : F64 := ndc_z + 1.0 in
    let ad : F64 := if d < 0.0 then 0.0 - d else d in
    ad < 0.0001

#[test]
def test_mat4_look_at_puts_eye_at_origin : Bool :=
    let eye : Vec3 := vec3 5.0 3.0 2.0 in
    let m : Mat4 := mat4_look_at eye (vec3 0.0 0.0 0.0) (vec3 0.0 1.0 0.0) in
    let p : Vec3 := mat4_transform_point m eye in
    v3_dot p p < 0.0001

#[test]
def test_mat4_look_at_center_is_forward : Bool :=
    let m : Mat4 := mat4_look_at (vec3 0.0 0.0 5.0) (vec3 0.0 0.0 0.0) (vec3 0.0 1.0 0.0) in
    // The camera looks down -z in view space, so the world origin lands on -z.
    let p : Vec3 := mat4_transform_point m (vec3 0.0 0.0 0.0) in
    p.z < (0.0 - 4.9999)

#[test]
def test_mat4_to_mat3_drops_translation : Bool :=
    let m : Mat4 := mat4_translate (vec3 9.0 9.0 9.0) in
    let m3 : Mat3 := mat4_to_mat3 m in
    let v : Vec3 := vec3 1.0 0.0 0.0 in
    let r : Vec3 := mat3_mul_vec3 m3 v in
    v3_dot r v > 0.9999
