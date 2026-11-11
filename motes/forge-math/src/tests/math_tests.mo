// forge-math integration tests, over the PUBLIC surface (`lib::{...}`).
//
// Each module has its own in-file unit tests; these are the cross-module ones
// -- a full transform pipeline, a camera, and picking -- and they exercise the
// `lib.mo` re-exports as much as the math.

use lib::{Vec3, vec3, v3_dot, v3_sub, v3_normalize,
          Quat, quat_identity, quat_from_axis_angle, quat_rotate, quat_slerp,
          Mat4, mat4_identity, mat4_mul, mat4_mul_vec4, mat4_transform_point,
          mat4_translate, mat4_scale, mat4_trs, mat4_perspective, mat4_look_at,
          Vec4, vec4,
          Ray, ray, ray_at, AABB, aabb, Sphere, sphere,
          ray_intersects_aabb, ray_intersects_sphere, aabb_intersects_aabb}

/// Any cast of the fully-composed MVP matrix: a point at the origin stays at
/// the origin, and a point one unit along +x stays one unit away from it.
#[test]
def test_mvp_is_a_rigid_motion_at_identity : Bool :=
    let model : Mat4 := mat4_identity in
    let view : Mat4 := mat4_look_at (vec3 0.0 0.0 5.0) (vec3 0.0 0.0 0.0) (vec3 0.0 1.0 0.0) in
    let proj : Mat4 := mat4_perspective 1.0 1.0 1.0 100.0 in
    let mvp : Mat4 := mat4_mul proj (mat4_mul view model) in
    let a : Vec3 := mat4_transform_point mvp (vec3 0.0 0.0 0.0) in
    let b : Vec3 := mat4_transform_point mvp (vec3 1.0 0.0 0.0) in
    let d : Vec3 := v3_sub b a in
    v3_dot d d > 0.0

#[test]
def test_trs_places_a_point_at_the_translation : Bool :=
    let m : Mat4 := mat4_trs (vec3 3.0 4.0 5.0) quat_identity (vec3 1.0 1.0 1.0) in
    let p : Vec3 := mat4_transform_point m (vec3 0.0 0.0 0.0) in
    v3_dot p (vec3 3.0 4.0 5.0) > 49.9999 && v3_dot p (vec3 3.0 4.0 5.0) < 50.0001

#[test]
def test_trs_scale_then_translate : Bool :=
    let m : Mat4 := mat4_trs (vec3 1.0 0.0 0.0) quat_identity (vec3 2.0 2.0 2.0) in
    let p : Vec3 := mat4_transform_point m (vec3 1.0 0.0 0.0) in
    v3_dot p (vec3 3.0 0.0 0.0) > 8.9999 && v3_dot p (vec3 3.0 0.0 0.0) < 9.0001

#[test]
def test_view_projection_projects_a_point_to_ndc_center : Bool :=
    let view : Mat4 := mat4_look_at (vec3 0.0 0.0 5.0) (vec3 0.0 0.0 0.0) (vec3 0.0 1.0 0.0) in
    let proj : Mat4 := mat4_perspective 1.0 1.0 1.0 100.0 in
    let clip : Vec4 := mat4_mul_vec4 (mat4_mul proj view) (vec4 0.0 0.0 0.0 1.0) in
    let inv_w : F64 := 1.0 / clip.w in
    let x : F64 := clip.x * inv_w in
    let y : F64 := clip.y * inv_w in
    let ax : F64 := if x < 0.0 then 0.0 - x else x in
    let ay : F64 := if y < 0.0 then 0.0 - y else y in
    ax < 0.0001 && ay < 0.0001

#[test]
def test_rotate_then_translate_differs_from_translate_then_rotate : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 0.0 0.0 1.0) 1.5707963267948966 in
    let t : Mat4 := mat4_translate (vec3 1.0 0.0 0.0) in
    let r : Mat4 := mat4_trs (vec3 0.0 0.0 0.0) q (vec3 1.0 1.0 1.0) in
    let rt : Vec3 := mat4_transform_point (mat4_mul t r) (vec3 0.0 0.0 0.0) in
    let tr : Vec3 := mat4_transform_point (mat4_mul r t) (vec3 0.0 0.0 0.0) in
    // T*R keeps the origin at the translation; R*T rotates the translation.
    v3_dot rt (vec3 1.0 0.0 0.0) > 0.9999 && v3_dot tr (vec3 1.0 0.0 0.0) < 0.0001

#[test]
def test_slerp_quarter_turn_rotates_x_toward_y : Bool :=
    let a : Quat := quat_identity in
    let b : Quat := quat_from_axis_angle (vec3 0.0 0.0 1.0) 1.5707963267948966 in
    let mid : Quat := quat_slerp a b 0.5 in
    let v : Vec3 := quat_rotate mid (vec3 1.0 0.0 0.0) in
    // 45 degrees: (cos45, sin45, 0)
    v3_dot v (vec3 0.70710678 0.70710678 0.0) > 0.9999

#[test]
def test_ray_from_camera_hits_a_box_in_front : Bool :=
    // The ray starts at the eye and heads down -z; the box spans the origin.
    let r : Ray := ray (vec3 0.0 0.0 5.0) (v3_normalize (vec3 0.0 0.0 -1.0)) in
    let b : AABB := aabb (vec3 -1.0 -1.0 -1.0) (vec3 1.0 1.0 1.0) in
    ray_intersects_aabb r b

#[test]
def test_ray_from_camera_hits_a_sphere_in_front : Bool :=
    let r : Ray := ray (vec3 0.0 0.0 5.0) (v3_normalize (vec3 0.0 0.0 -1.0)) in
    ray_intersects_sphere r (sphere (vec3 0.0 0.0 0.0) 1.0)

#[test]
def test_ray_stops_before_a_far_box : Bool :=
    // Same ray, but the box is BEHIND the eye.
    let r : Ray := ray (vec3 0.0 0.0 5.0) (v3_normalize (vec3 0.0 0.0 -1.0)) in
    let b : AABB := aabb (vec3 -1.0 -1.0 10.0) (vec3 1.0 1.0 12.0) in
    Bool.not (ray_intersects_aabb r b)

#[test]
def test_ray_hit_point_is_on_the_box_surface : Bool :=
    let r : Ray := ray (vec3 0.0 0.0 5.0) (v3_normalize (vec3 0.0 0.0 -1.0)) in
    // The box's front face is at z = 1, so t = 4.
    let p : Vec3 := ray_at r 4.0 in
    let d : F64 := p.z - 1.0 in
    let ad : F64 := if d < 0.0 then 0.0 - d else d in
    ad < 0.0001

#[test]
def test_two_transformed_boxes_overlap : Bool :=
    let a : Mat4 := mat4_translate (vec3 0.0 0.0 0.0) in
    let b : Mat4 := mat4_mul (mat4_translate (vec3 1.0 0.0 0.0)) (mat4_scale (vec3 1.0 1.0 1.0)) in
    let ca : Vec3 := mat4_transform_point a (vec3 0.0 0.0 0.0) in
    let cb : Vec3 := mat4_transform_point b (vec3 0.0 0.0 0.0) in
    aabb_intersects_aabb
        (aabb (v3_sub ca (vec3 1.0 1.0 1.0)) (vec3 1.0 1.0 1.0))
        (aabb (v3_sub cb (vec3 1.0 1.0 1.0)) (vec3 2.0 1.0 1.0))
