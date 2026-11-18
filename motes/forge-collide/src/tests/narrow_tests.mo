// forge-collide narrow phase: closed forms on analytic cases, and GJK/EPA
// held to the closed forms over a table of poses.

use lib::{
    Pose, pose_at, pose_new, Shape, shape_sphere, shape_box, shape_capsule, shape_plane, shape_convex,
    Proximity, proximity, proximity_gjk, prox_distance, prox_normal, prox_pa, prox_pb,
    collide, overlaps, Contact, contact_depth, contact_normal
}
use forge_math {Vec3, vec3, v3_distance, v3_dot, Quat, quat_from_axis_angle, f64_abs}

def near (a : F64) (b : F64) : Bool := f64_abs (a - b) < 0.000001

def near_eps (e : F64) (a : F64) (b : F64) : Bool := f64_abs (a - b) < e

def vnear (a : Vec3) (b : Vec3) : Bool := v3_distance a b < 0.000001

def at (x : F64) (y : F64) (z : F64) : Pose := pose_at (vec3 x y z)

def unit_cube : Shape := shape_box (vec3 0.5 0.5 0.5)

// ── Closed forms ────────────────────────────────────────────────────

#[test]
def test_sphere_pair_apart : Bool :=
    let p : Proximity := proximity (shape_sphere 1.0) (at 0.0 0.0 0.0) (shape_sphere 0.5) (at 3.0 0.0 0.0) in
    near (prox_distance p) 1.5 && vnear (prox_normal p) (vec3 1.0 0.0 0.0)
        && vnear (prox_pa p) (vec3 1.0 0.0 0.0) && vnear (prox_pb p) (vec3 2.5 0.0 0.0)

#[test]
def test_spheres_touching : Bool :=
    near (prox_distance (proximity (shape_sphere 1.0) (at 0.0 0.0 0.0) (shape_sphere 1.0) (at 0.0 2.0 0.0))) 0.0

#[test]
def test_spheres_deep : Bool :=
    let p : Proximity := proximity (shape_sphere 1.0) (at 0.0 0.0 0.0) (shape_sphere 1.0) (at 0.0 0.0 0.5) in
    near (prox_distance p) (0.0 - 1.5) && vnear (prox_normal p) (vec3 0.0 0.0 1.0)

#[test]
def test_capsules_crossed : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 0.0 0.0 1.0) 1.5707963267948966 in
    let p : Proximity := proximity (shape_capsule 0.5 1.0) (at 0.0 0.0 0.0)
                                   (shape_capsule 0.25 1.0) (pose_new (vec3 0.0 0.0 2.0) q) in
    near (prox_distance p) 1.25

#[test]
def test_capsule_end_on_sphere : Bool :=
    near (prox_distance (proximity (shape_capsule 0.5 1.0) (at 0.0 0.0 0.0) (shape_sphere 0.5) (at 0.0 3.0 0.0))) 1.0

#[test]
def test_sphere_on_box_face : Bool :=
    let p : Proximity := proximity unit_cube (at 0.0 0.0 0.0) (shape_sphere 0.25) (at 0.0 1.0 0.0) in
    near (prox_distance p) 0.25 && vnear (prox_normal p) (vec3 0.0 1.0 0.0)

#[test]
def test_sphere_at_box_corner : Bool :=
    let p : Proximity := proximity (shape_sphere 0.1) (at 1.5 1.5 0.5) unit_cube (at 0.0 0.0 0.0) in
    near (prox_distance p) (1.4142135623730951 - 0.1)

#[test]
def test_sphere_centre_inside_box : Bool :=
    let p : Proximity := proximity unit_cube (at 0.0 0.0 0.0) (shape_sphere 0.1) (at 0.4 0.0 0.0) in
    near (prox_distance p) (0.0 - 0.2) && vnear (prox_normal p) (vec3 1.0 0.0 0.0)

#[test]
def test_box_resting_on_plane : Bool :=
    let p : Proximity := proximity (shape_plane (vec3 0.0 1.0 0.0) 0.0) (at 0.0 0.0 0.0) unit_cube (at 0.0 0.4 0.0) in
    near (prox_distance p) (0.0 - 0.1) && vnear (prox_normal p) (vec3 0.0 1.0 0.0)

#[test]
def test_capsule_above_plane_from_its_side : Bool :=
    let p : Proximity := proximity (shape_capsule 0.3 0.5) (at 0.0 2.0 0.0) (shape_plane (vec3 0.0 1.0 0.0) 0.0) (at 0.0 0.0 0.0) in
    near (prox_distance p) 1.2 && vnear (prox_normal p) (vec3 0.0 (0.0 - 1.0) 0.0)

#[test]
def test_boxes_overlap_by_sat : Bool :=
    let p : Proximity := proximity unit_cube (at 0.0 0.0 0.0) unit_cube (at 0.9 0.2 0.0) in
    near (prox_distance p) (0.0 - 0.1) && vnear (prox_normal p) (vec3 1.0 0.0 0.0)

#[test]
def test_rotated_boxes_apart_edge_to_face : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 0.0 0.0 1.0) 0.7853981633974483 in
    let p : Proximity := proximity unit_cube (at 0.0 0.0 0.0) unit_cube (pose_new (vec3 0.0 2.0 0.0) q) in
    near (prox_distance p) (1.5 - 0.7071067811865476)

#[test]
def test_collide_gives_depth : Bool :=
    match collide (shape_sphere 1.0) (at 0.0 0.0 0.0) (shape_sphere 1.0) (at 1.5 0.0 0.0) {
        Option.some c0 => let c : Contact := c0 in near (contact_depth c) 0.5 && vnear (contact_normal c) (vec3 1.0 0.0 0.0),
        Option.none => false
    }

#[test]
def test_collide_none_when_apart : Bool :=
    match collide unit_cube (at 0.0 0.0 0.0) unit_cube (at 2.0 0.0 0.0) {
        Option.some _ => false,
        Option.none => true
    }

// ── GJK / EPA against the closed forms ──────────────────────────────

def agree (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Bool :=
    let c : Proximity := proximity sa xa sb xb in
    let g : Proximity := proximity_gjk sa xa sb xb in
    near_eps 0.000001 (prox_distance c) (prox_distance g)

def tilt (a : F64) : Quat := quat_from_axis_angle (vec3 1.0 0.3 0.2) a

#[test]
def test_gjk_agrees_sphere_box_table : Bool :=
    agree unit_cube (at 0.0 0.0 0.0) (shape_sphere 0.3) (at 1.2 0.1 0.0)
        && agree unit_cube (pose_new (vec3 0.0 0.0 0.0) (tilt 0.6)) (shape_sphere 0.3) (at 1.0 1.0 0.2)
        && agree unit_cube (at 0.0 0.0 0.0) (shape_sphere 0.2) (at 0.9 0.9 0.9)
        && agree unit_cube (pose_new (vec3 1.0 0.0 0.0) (tilt 1.3)) (shape_sphere 0.5) (at (0.0 - 1.0) 0.5 0.0)

#[test]
def test_gjk_agrees_capsules_table : Bool :=
    agree (shape_capsule 0.3 0.5) (at 0.0 0.0 0.0) (shape_capsule 0.2 0.8) (pose_new (vec3 1.5 0.2 0.0) (tilt 0.9))
        && agree (shape_capsule 0.3 0.5) (pose_new (vec3 0.0 0.0 0.0) (tilt 0.4)) (shape_sphere 0.4) (at 0.3 2.0 0.1)
        && agree (shape_sphere 0.5) (at 0.0 0.0 0.0) (shape_sphere 0.25) (at 1.0 1.0 1.0)

#[test]
def test_gjk_agrees_boxes_apart : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 0.0 0.0 1.0) 0.7853981633974483 in
    agree unit_cube (at 0.0 0.0 0.0) unit_cube (pose_new (vec3 0.0 2.0 0.0) q)
        && agree unit_cube (at 0.0 0.0 0.0) unit_cube (at 1.5 1.5 0.0)

#[test]
def test_epa_matches_sat_on_overlap : Bool :=
    let a : Shape := shape_convex [vec3 (0.0 - 0.5) (0.0 - 0.5) (0.0 - 0.5), vec3 0.5 (0.0 - 0.5) (0.0 - 0.5),
                                   vec3 (0.0 - 0.5) 0.5 (0.0 - 0.5), vec3 0.5 0.5 (0.0 - 0.5),
                                   vec3 (0.0 - 0.5) (0.0 - 0.5) 0.5, vec3 0.5 (0.0 - 0.5) 0.5,
                                   vec3 (0.0 - 0.5) 0.5 0.5, vec3 0.5 0.5 0.5] in
    let p : Proximity := proximity a (at 0.0 0.0 0.0) unit_cube (at 0.0 0.8 0.1) in
    near_eps 0.00001 (prox_distance p) (0.0 - 0.2) && near_eps 0.00001 (v3_dot (prox_normal p) (vec3 0.0 1.0 0.0)) 1.0

#[test]
def test_epa_deep_capsule_in_box : Bool :=
    let p : Proximity := proximity (shape_capsule 0.25 0.25) (at 0.0 0.6 0.0) (shape_box (vec3 2.0 0.5 2.0)) (at 0.0 0.0 0.0) in
    near_eps 0.00001 (prox_distance p) (0.0 - 0.4) && near_eps 0.00001 (v3_dot (prox_normal p) (vec3 0.0 (0.0 - 1.0) 0.0)) 1.0

#[test]
def test_hull_triangle_prism_distance : Bool :=
    let tri : Shape := shape_convex [vec3 0.0 0.0 0.0, vec3 1.0 0.0 0.0, vec3 0.0 1.0 0.0,
                                     vec3 0.0 0.0 1.0, vec3 1.0 0.0 1.0, vec3 0.0 1.0 1.0] in
    near (prox_distance (proximity tri (at 0.0 0.0 0.0) (shape_sphere 0.1) (at 1.0 1.0 0.5)))
         (0.7071067811865476 - 0.1)

#[test]
def test_overlaps_is_symmetric : Bool :=
    overlaps unit_cube (at 0.0 0.0 0.0) (shape_capsule 0.3 0.5) (at 0.0 0.9 0.0)
        && overlaps (shape_capsule 0.3 0.5) (at 0.0 0.9 0.0) unit_cube (at 0.0 0.0 0.0)
