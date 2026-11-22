// forge-math: Vec2/Vec3/Vec4, Quat, Mat3/Mat4, and intersection primitives.
// Phase 3, see ../../../PLAN.md.
//
// `num` is the F64 layer the rest of this mote is built on (there is no
// `sqrt`/`sin`/`cos`/int->float in the toolchain). Only the handful of
// scalars a CONSUMER cannot do without are re-exported -- a mesh builder
// needs `sin`/`cos` and a segment count as a float, a game needs an angle --
// the approximation helpers stay private.
//
// `Array` is not usable (not `pub` in `std::array`), and the toolchain ships no
// generic `Vec (N : I64)` that could derive `Copy`, so each vector size is its
// own monomorphic struct (`Vec2`/`Vec3`/`Vec4`) and each operation is suffixed
// by size (`v3_add`, `v2_dot`, ...).

pub use lib::num {
    f64_pi, f64_half_pi, f64_tau, f64_abs, f64_min, f64_max, f64_clamp, f64_sqrt,
    f64_sin, f64_cos, f64_wrap_angle, f64_round, f64_floor, f64_of_i64
}
pub use lib::vec {
    Vec2, vec2, v2_zero, v2_one, v2_add, v2_sub, v2_scale, v2_neg, v2_dot,
    v2_length_sq, v2_length, v2_distance, v2_normalize, v2_perp, v2_lerp,
    Vec3, vec3, v3_zero, v3_one, v3_up, v3_add, v3_sub, v3_scale, v3_neg,
    v3_dot, v3_cross, v3_length_sq, v3_length, v3_distance, v3_normalize,
    v3_lerp, v3_reflect,
    Vec4, vec4, v4_zero, v4_add, v4_sub, v4_scale, v4_dot, v4_length_sq,
    v4_length, v4_normalize, v4_to_v3
}
pub use lib::quat {
    Quat, quat, quat_identity, quat_conj, quat_length_sq, quat_length,
    quat_normalize, quat_mul, quat_vec, quat_rotate, quat_rotate_inv,
    quat_from_axis_angle, quat_from_z_angle, quat_lerp, quat_slerp, quat_angle,
    quat_same_rotation
}
pub use lib::mat {
    Mat3, mat3, mat3_identity, mat3_col_x, mat3_col_y, mat3_col_z,
    mat3_mul_vec3, mat3_mul, mat3_transpose,
    Mat4, mat4, mat4_col_x, mat4_col_y, mat4_col_z, mat4_col_w,
    mat4_translation, mat4_identity, mat4_mul_vec4, mat4_mul,
    mat4_transform_point, mat4_transform_dir, mat4_translate, mat4_scale,
    mat4_uniform_scale, mat4_from_quat, mat4_rotate_axis_angle, mat4_trs,
    mat4_transpose, mat4_perspective, mat4_orthographic, mat4_look_at,
    mat4_to_mat3, mat4_to_list, mat4_inverse, mat4_max_diff
}
pub use lib::intersect {
    Ray, ray, ray_at, ray_normalize,
    Plane, plane, plane_from_point_normal, plane_distance, plane_normalize,
    AABB, aabb, aabb_from_center_half, aabb_center, aabb_half_extents,
    aabb_contains,
    Sphere, sphere,
    ray_intersects_sphere, ray_intersects_aabb, aabb_intersects_aabb,
    sphere_intersects_sphere, ray_intersects_plane,
    ray_sphere_hit, ray_aabb_hit, ray_plane_hit, screen_to_ray
}
