// forge-math: Ray / Plane / AABB / Sphere and their intersection predicates.
//
// All boolean "does X hit Y". The ray/AABB test is the slab method: it divides
// by each direction component, which yields `+-inf` for an axis-aligned ray and
// then folds away correctly in the `min`/`max` (IEEE infinities compare the
// ordinary way, and `f64_div` is a C `double` divide).

use std::derive {}
use lib::vec {
    Vec3, vec3, v3_add, v3_sub, v3_scale, v3_dot, v3_normalize, v3_length, v3_length_sq
}
use lib::num {f64_abs, f64_min, f64_max, f64_sqrt}

// ── Shapes ──────────────────────────────────────────────────────────

/// A ray: `origin + t * direction`, `t >= 0`.
#[derive Copy Clone Debug]
pub struct Ray {
    origin : Vec3,
    direction : Vec3
}

pub def ray (origin : Vec3) (direction : Vec3) : Ray :=
    { origin := origin, direction := direction : Ray }

pub def ray_at (r : Ray) (t : F64) : Vec3 := v3_add r.origin (v3_scale r.direction t)

pub def ray_normalize (r : Ray) : Ray :=
    { origin := r.origin, direction := v3_normalize r.direction : Ray }

/// The plane `normal . x + d = 0`, `normal` unit.
#[derive Copy Clone Debug]
pub struct Plane {
    normal : Vec3,
    d : F64
}

pub def plane (normal : Vec3) (d : F64) : Plane := { normal := normal, d := d : Plane }

pub def plane_from_point_normal (p : Vec3) (n : Vec3) : Plane :=
    { normal := n, d := 0.0 - v3_dot n p : Plane }

/// Signed distance from `p` to the plane (positive on the `normal` side).
pub def plane_distance (pl : Plane) (p : Vec3) : F64 := v3_dot pl.normal p + pl.d

pub def plane_normalize (pl : Plane) : Plane :=
    let inv : F64 := 1.0 / v3_length pl.normal in
    { normal := v3_scale pl.normal inv, d := pl.d * inv : Plane }

/// An axis-aligned box, `min <= max` component-wise.
#[derive Copy Clone Debug]
pub struct AABB {
    min : Vec3,
    max : Vec3
}

pub def aabb (min : Vec3) (max : Vec3) : AABB := { min := min, max := max : AABB }

pub def aabb_from_center_half (c : Vec3) (h : Vec3) : AABB :=
    { min := v3_sub c h, max := v3_add c h : AABB }

pub def aabb_center (b : AABB) : Vec3 := v3_scale (v3_add b.min b.max) 0.5

pub def aabb_half_extents (b : AABB) : Vec3 := v3_scale (v3_sub b.max b.min) 0.5

pub def aabb_contains (b : AABB) (p : Vec3) : Bool :=
    p.x >= b.min.x && p.x <= b.max.x
        && p.y >= b.min.y && p.y <= b.max.y
        && p.z >= b.min.z && p.z <= b.max.z

#[derive Copy Clone Debug]
pub struct Sphere {
    center : Vec3,
    radius : F64
}

pub def sphere (center : Vec3) (radius : F64) : Sphere :=
    { center := center, radius := radius : Sphere }

// ── Intersections ───────────────────────────────────────────────────

/// Does the ray hit the sphere in the forward direction?
pub def ray_intersects_sphere (r : Ray) (s : Sphere) : Bool :=
    let oc : Vec3 := v3_sub r.origin s.center in
    let b : F64 := v3_dot oc r.direction in
    let c : F64 := v3_dot oc oc - s.radius * s.radius in
    let disc : F64 := b * b - c in
    if disc < 0.0 then false else (0.0 - b) + f64_sqrt disc >= 0.0

pub def ray_intersects_aabb (r : Ray) (b : AABB) : Bool :=
    let inv_x : F64 := 1.0 / r.direction.x in
    let inv_y : F64 := 1.0 / r.direction.y in
    let inv_z : F64 := 1.0 / r.direction.z in
    let t1x : F64 := (b.min.x - r.origin.x) * inv_x in
    let t2x : F64 := (b.max.x - r.origin.x) * inv_x in
    let t1y : F64 := (b.min.y - r.origin.y) * inv_y in
    let t2y : F64 := (b.max.y - r.origin.y) * inv_y in
    let t1z : F64 := (b.min.z - r.origin.z) * inv_z in
    let t2z : F64 := (b.max.z - r.origin.z) * inv_z in
    let tnear : F64 := f64_max (f64_max (f64_min t1x t2x) (f64_min t1y t2y)) (f64_min t1z t2z) in
    let tfar : F64 := f64_min (f64_min (f64_max t1x t2x) (f64_max t1y t2y)) (f64_max t1z t2z) in
    tfar >= 0.0 && tnear <= tfar

pub def aabb_intersects_aabb (a : AABB) (b : AABB) : Bool :=
    a.min.x <= b.max.x && a.max.x >= b.min.x
        && a.min.y <= b.max.y && a.max.y >= b.min.y
        && a.min.z <= b.max.z && a.max.z >= b.min.z

pub def sphere_intersects_sphere (a : Sphere) (b : Sphere) : Bool :=
    let r : F64 := a.radius + b.radius in
    v3_length_sq (v3_sub a.center b.center) <= r * r

/// Does the ray cross the plane in the forward direction? A parallel ray is a
/// miss (unless it lies *in* the plane, which is not "crossing" it).
pub def ray_intersects_plane (r : Ray) (pl : Plane) : Bool :=
    let denom : F64 := v3_dot pl.normal r.direction in
    if f64_abs denom < 0.0000001
    then false
    else (0.0 - (v3_dot pl.normal r.origin + pl.d)) / denom >= 0.0

#[test]
def test_ray_at : Bool :=
    let r : Ray := ray (vec3 0.0 0.0 0.0) (vec3 1.0 2.0 3.0) in
    let p : Vec3 := ray_at r 1.0 in
    v3_dot p (vec3 1.0 2.0 3.0) > 13.9999 && v3_dot p (vec3 1.0 2.0 3.0) < 14.0001

#[test]
def test_ray_hits_sphere_head_on : Bool :=
    ray_intersects_sphere (ray (vec3 0.0 0.0 0.0) (vec3 1.0 0.0 0.0)) (sphere (vec3 10.0 0.0 0.0) 1.0)

#[test]
def test_ray_misses_sphere : Bool :=
    Bool.not (ray_intersects_sphere (ray (vec3 0.0 5.0 0.0) (vec3 1.0 0.0 0.0)) (sphere (vec3 10.0 0.0 0.0) 1.0))

#[test]
def test_ray_pointing_away_misses : Bool :=
    Bool.not (ray_intersects_sphere (ray (vec3 0.0 0.0 0.0) (vec3 0.0 (0.0 - 1.0) 0.0)) (sphere (vec3 0.0 10.0 0.0) 1.0))

#[test]
def test_ray_hits_aabb : Bool :=
    ray_intersects_aabb (ray (vec3 0.0 0.0 0.0) (vec3 1.0 0.0 0.0)) (aabb (vec3 4.0 -1.0 -1.0) (vec3 6.0 1.0 1.0))

#[test]
def test_ray_misses_aabb : Bool :=
    Bool.not (ray_intersects_aabb (ray (vec3 0.0 5.0 0.0) (vec3 1.0 0.0 0.0)) (aabb (vec3 4.0 -1.0 -1.0) (vec3 6.0 1.0 1.0)))

#[test]
def test_axis_aligned_ray_hits_aabb : Bool :=
    // direction is (0,0,-1): the x and y slabs divide by zero, giving +-inf.
    ray_intersects_aabb (ray (vec3 0.5 0.5 10.0) (vec3 0.0 0.0 -1.0)) (aabb (vec3 0.0 0.0 0.0) (vec3 1.0 1.0 1.0))

#[test]
def test_ray_behind_aabb_misses : Bool :=
    Bool.not (ray_intersects_aabb (ray (vec3 0.0 0.0 -5.0) (vec3 0.0 0.0 -1.0)) (aabb (vec3 -1.0 -1.0 -1.0) (vec3 1.0 1.0 1.0)))

#[test]
def test_aabb_overlap : Bool :=
    aabb_intersects_aabb (aabb (vec3 0.0 0.0 0.0) (vec3 2.0 2.0 2.0)) (aabb (vec3 1.0 1.0 1.0) (vec3 3.0 3.0 3.0))

#[test]
def test_aabb_separated : Bool :=
    Bool.not (aabb_intersects_aabb (aabb (vec3 0.0 0.0 0.0) (vec3 1.0 1.0 1.0)) (aabb (vec3 2.0 2.0 2.0) (vec3 3.0 3.0 3.0)))

#[test]
def test_spheres_overlap : Bool :=
    sphere_intersects_sphere (sphere (vec3 0.0 0.0 0.0) 1.0) (sphere (vec3 1.5 0.0 0.0) 1.0)

#[test]
def test_spheres_apart : Bool :=
    Bool.not (sphere_intersects_sphere (sphere (vec3 0.0 0.0 0.0) 1.0) (sphere (vec3 3.0 0.0 0.0) 1.0))

#[test]
def test_ray_hits_plane : Bool :=
    ray_intersects_plane (ray (vec3 0.0 0.0 0.0) (vec3 0.0 0.0 -1.0)) (plane (vec3 0.0 0.0 1.0) 5.0)

#[test]
def test_ray_parallel_to_plane_misses : Bool :=
    Bool.not (ray_intersects_plane (ray (vec3 0.0 0.0 0.0) (vec3 1.0 0.0 0.0)) (plane (vec3 0.0 1.0 0.0) 5.0))

#[test]
def test_plane_distance_sign : Bool :=
    plane_distance (plane (vec3 0.0 1.0 0.0) 0.0) (vec3 0.0 3.0 0.0) > 2.9999

#[test]
def test_aabb_center_and_half_extents : Bool :=
    let b : AABB := aabb (vec3 0.0 0.0 0.0) (vec3 4.0 2.0 6.0) in
    let c : Vec3 := aabb_center b in
    let h : Vec3 := aabb_half_extents b in
    f64_abs (c.x - 2.0) < 0.0001 && f64_abs (h.z - 3.0) < 0.0001

#[test]
def test_aabb_contains : Bool :=
    let b : AABB := aabb (vec3 -1.0 -1.0 -1.0) (vec3 1.0 1.0 1.0) in
    aabb_contains b (vec3 0.5 0.5 0.5) && Bool.not (aabb_contains b (vec3 2.0 0.0 0.0))
