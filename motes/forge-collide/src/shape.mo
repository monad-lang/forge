// forge-collide: shapes, poses and the `Collider` component.
//
// Every convex shape is a CORE (a point, a segment, a box or a hull) grown
// by a MARGIN (its radius): a sphere is a point plus `r`, a capsule a segment
// plus `r`. Distance and contact work on the cores and add the margins back,
// so a new shape only needs `support_core` (the farthest core point in a
// direction) and its `shape_margin`.
//
// A `Pose` is a rigid placement: a position and three orthonormal axes. It
// is built from an entity's `Transform` (roots) or `GlobalTransform`
// (children); scale is ignored, because shapes carry their own sizes.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, get_component_named, insert_component}
use forge_math {
    Vec3, vec3, v3_zero, v3_add, v3_sub, v3_scale, v3_dot, v3_length, v3_normalize,
    Quat, quat_rotate, quat_from_axis_angle, Mat4, mat4_col_x, mat4_col_y, mat4_col_z, mat4_translation,
    Vec4, AABB, aabb, f64_abs, f64_min, f64_max
}
use forge_scene {Transform, entity_transform, entity_global, has_parent}

// ── Pose ────────────────────────────────────────────────────────────

/// A rigid placement: `pos` plus orthonormal axes. `Copy`.
#[derive Copy Clone]
pub struct Pose {
    pos : Vec3,
    ax : Vec3,
    ay : Vec3,
    az : Vec3
}

pub def pose_at (p : Vec3) : Pose :=
    { pos := p, ax := vec3 1.0 0.0 0.0, ay := vec3 0.0 1.0 0.0, az := vec3 0.0 0.0 1.0 : Pose }

pub def pose_identity : Pose := pose_at v3_zero

pub def pose_new (p : Vec3) (q : Quat) : Pose :=
    { pos := p,
      ax := quat_rotate q (vec3 1.0 0.0 0.0),
      ay := quat_rotate q (vec3 0.0 1.0 0.0),
      az := quat_rotate q (vec3 0.0 0.0 1.0)
      : Pose }

def v4_xyz (v : Vec4) : Vec3 := vec3 v.x v.y v.z

/// The rigid part of an affine matrix: its translation and its normalized
/// basis columns (scale is dropped).
pub def pose_from_matrix (m : Mat4) : Pose :=
    { pos := mat4_translation m,
      ax := v3_normalize (v4_xyz (mat4_col_x m)),
      ay := v3_normalize (v4_xyz (mat4_col_y m)),
      az := v3_normalize (v4_xyz (mat4_col_z m))
      : Pose }

pub def pose_pos (x : Pose) : Vec3 := x.pos

pub def pose_with_pos (x : Pose) (p : Vec3) : Pose :=
    { pos := p, ax := x.ax, ay := x.ay, az := x.az : Pose }

pub def pose_translate (x : Pose) (d : Vec3) : Pose := pose_with_pos x (v3_add x.pos d)

/// A local direction in world space.
pub def pose_dir (x : Pose) (d : Vec3) : Vec3 :=
    v3_add (v3_scale x.ax d.x) (v3_add (v3_scale x.ay d.y) (v3_scale x.az d.z))

/// A local point in world space.
pub def pose_point (x : Pose) (p : Vec3) : Vec3 := v3_add x.pos (pose_dir x p)

/// A world direction in local space.
pub def pose_inv_dir (x : Pose) (d : Vec3) : Vec3 :=
    vec3 (v3_dot d x.ax) (v3_dot d x.ay) (v3_dot d x.az)

/// A world point in local space.
pub def pose_inv_point (x : Pose) (p : Vec3) : Vec3 := pose_inv_dir x (v3_sub p x.pos)

// ── Shapes ──────────────────────────────────────────────────────────

/// A collision shape in its local frame, centred on the origin.
/// `plane_shape n d` is the solid half-space `n . p + d <= 0` (`n` unit,
/// pointing out of the solid); it is static and infinite.
pub type Shape {
    sphere_shape (r : F64),
    box_shape (half : Vec3),
    capsule_shape (r : F64) (hh : F64),
    plane_shape (normal : Vec3) (d : F64),
    convex_shape (points : List Vec3)
}

pub instance Copy Shape {
    def copy (s : Shape) : Pair Shape Shape := Pair.pair s s
}

pub def shape_sphere (r : F64) : Shape := Shape.sphere_shape r

/// A box with half-extents `half` (oriented by the pose, so an OBB).
pub def shape_box (half : Vec3) : Shape := Shape.box_shape half

/// A capsule along local y: radius `r`, segment from `-hh` to `+hh`.
pub def shape_capsule (r : F64) (hh : F64) : Shape := Shape.capsule_shape r hh

pub def shape_plane (normal : Vec3) (d : F64) : Shape := Shape.plane_shape (v3_normalize normal) d

/// The convex hull of `points` (local space).
pub def shape_convex (points : List Vec3) : Shape := Shape.convex_shape points

pub def shape_is_plane (s : Shape) : Bool :=
    match s {
        Shape.plane_shape _ _ => true,
        Shape.sphere_shape _ => false,
        Shape.box_shape _ => false,
        Shape.capsule_shape _ _ => false,
        Shape.convex_shape _ => false
    }

/// The radius grown around the core.
pub def shape_margin (s : Shape) : F64 :=
    match s {
        Shape.sphere_shape r => r,
        Shape.capsule_shape r _ => r,
        Shape.box_shape _ => 0.0,
        Shape.plane_shape _ _ => 0.0,
        Shape.convex_shape _ => 0.0
    }

def sgn (x : F64) (h : F64) : F64 := if x < 0.0 then 0.0 - h else h

#[terminating]
def hull_support (best : Vec3) (best_d : F64) (d : Vec3) (ps : List Vec3) : Vec3 :=
    match ps {
        List.empty => best,
        List.cons p rest =>
            let pd : F64 := v3_dot p d in
            if pd > best_d then hull_support p pd d rest else hull_support best best_d d rest
    }

/// The farthest CORE point along local direction `d`.
pub def support_core (s : Shape) (d : Vec3) : Vec3 :=
    match s {
        Shape.sphere_shape _ => v3_zero,
        Shape.capsule_shape _ hh => vec3 0.0 (sgn d.y hh) 0.0,
        Shape.box_shape h => vec3 (sgn d.x h.x) (sgn d.y h.y) (sgn d.z h.z),
        Shape.plane_shape _ _ => v3_zero,
        Shape.convex_shape ps =>
            match ps {
                List.empty => v3_zero,
                List.cons p rest => hull_support p (v3_dot p d) d rest
            }
    }

/// The farthest core point along WORLD direction `d`, in world space.
pub def support_core_world (s : Shape) (x : Pose) (d : Vec3) : Vec3 :=
    pose_point x (support_core s (pose_inv_dir x d))

/// The farthest point of the full shape (core + margin) along world `d`.
pub def support_world (s : Shape) (x : Pose) (d : Vec3) : Vec3 :=
    let len : F64 := v3_length d in
    let core : Vec3 := support_core_world s x d in
    if len > 0.0 then v3_add core (v3_scale d (shape_margin s / len)) else core

// ── Bounds ──────────────────────────────────────────────────────────

/// How far the plane's "box" reaches: planes are infinite, so the broad
/// phase treats them specially, but a bound keeps queries total.
pub def plane_reach : F64 := 1000000000.0

def abs3 (v : Vec3) : Vec3 := vec3 (f64_abs v.x) (f64_abs v.y) (f64_abs v.z)

def grow (b : AABB) (m : F64) : AABB :=
    aabb (v3_sub b.min (vec3 m m m)) (v3_add b.max (vec3 m m m))

def extent_of (x : Pose) (h : Vec3) : Vec3 :=
    v3_add (v3_scale (abs3 x.ax) h.x) (v3_add (v3_scale (abs3 x.ay) h.y) (v3_scale (abs3 x.az) h.z))

#[terminating]
def hull_bounds (b : AABB) (x : Pose) (ps : List Vec3) : AABB :=
    match ps {
        List.empty => b,
        List.cons p rest =>
            let w : Vec3 := pose_point x p in
            hull_bounds (aabb (vec3 (f64_min b.min.x w.x) (f64_min b.min.y w.y) (f64_min b.min.z w.z))
                              (vec3 (f64_max b.max.x w.x) (f64_max b.max.y w.y) (f64_max b.max.z w.z)))
                        x rest
    }

/// The world-space bounding box of a posed shape.
pub def shape_aabb (s : Shape) (x : Pose) : AABB :=
    match s {
        Shape.sphere_shape r => grow (aabb x.pos x.pos) r,
        Shape.capsule_shape r hh =>
            let e : Vec3 := extent_of x (vec3 0.0 hh 0.0) in
            grow (aabb (v3_sub x.pos e) (v3_add x.pos e)) r,
        Shape.box_shape h =>
            let e : Vec3 := extent_of x h in
            aabb (v3_sub x.pos e) (v3_add x.pos e),
        Shape.plane_shape _ _ => grow (aabb x.pos x.pos) plane_reach,
        Shape.convex_shape ps => hull_bounds (aabb x.pos x.pos) x ps
    }

/// A plane shape's world normal and offset (`n . p + d <= 0` is solid).
pub def plane_world (n : Vec3) (d : F64) (x : Pose) : Pair Vec3 F64 :=
    let wn : Vec3 := pose_dir x n in
    Pair.pair wn (d - v3_dot wn x.pos)

// ── Collider ────────────────────────────────────────────────────────

/// A shape on an entity. `offset` moves it in the entity's local frame.
/// `layer` is the bit set the collider is in, `mask` the bits it collides
/// with; two colliders interact when each one's layer meets the other's
/// mask. A trigger reports overlaps but never pushes anything. `Copy`.
pub struct Collider {
    shape : Shape,
    offset : Vec3,
    layer : I64,
    mask : I64,
    is_trigger : Bool
}

pub instance Copy Collider {
    def copy (c : Collider) : Pair Collider Collider := Pair.pair c c
}

pub def layer_all : I64 := 0 - 1

pub def layer_default : I64 := 1

pub def collider (s : Shape) : Collider :=
    { shape := s, offset := v3_zero, layer := layer_default, mask := layer_all, is_trigger := false
      : Collider }

pub def collider_trigger (s : Shape) : Collider :=
    { shape := s, offset := v3_zero, layer := layer_default, mask := layer_all, is_trigger := true
      : Collider }

pub def collider_with_offset (c : Collider) (o : Vec3) : Collider :=
    { shape := c.shape, offset := o, layer := c.layer, mask := c.mask, is_trigger := c.is_trigger
      : Collider }

pub def collider_with_layers (c : Collider) (layer : I64) (mask : I64) : Collider :=
    { shape := c.shape, offset := c.offset, layer := layer, mask := mask, is_trigger := c.is_trigger
      : Collider }

pub def collider_shape (c : Collider) : Shape := c.shape

pub def collider_offset (c : Collider) : Vec3 := c.offset

pub def collider_layer (c : Collider) : I64 := c.layer

pub def collider_mask (c : Collider) : I64 := c.mask

pub def collider_is_trigger (c : Collider) : Bool := c.is_trigger

/// Each side's layer meets the other's mask.
pub def layers_interact (a : Collider) (b : Collider) : Bool :=
    Bool.not (I64.and a.layer b.mask == 0) && Bool.not (I64.and b.layer a.mask == 0)

/// A query mask accepts `c` when it meets `c`'s layer.
pub def mask_accepts (mask : I64) (c : Collider) : Bool := Bool.not (I64.and mask c.layer == 0)

pub def collider_name : String := "forge.collider"

def as_collider (v : Any) : Collider :=
    match v { Any.any x => let c : Collider := x in c }

pub def entity_collider (world : World) (e : Entity) : Option Collider :=
    match get_component_named world e collider_name {
        Option.some v => Option.some (as_collider v),
        Option.none => Option.none
    }

pub def set_collider (world : World) (e : Entity) (c : Collider) : World :=
    insert_component world e collider_name (Any.any c)

/// The entity's rigid pose: its local `Transform` for a root (current this
/// frame), its propagated `GlobalTransform` for a child.
pub def entity_pose (world : World) (e : Entity) : Pose :=
    if has_parent world e
    then
        match entity_global world e {
            Option.some m => pose_from_matrix m,
            Option.none => pose_identity
        }
    else
        match entity_transform world e {
            Option.some t0 => let t : Transform := t0 in pose_new t.translation t.rotation,
            Option.none => pose_identity
        }

/// Where `c` sits when its entity is at `x`.
pub def collider_pose (c : Collider) (x : Pose) : Pose := pose_with_pos x (pose_point x c.offset)

// ── Tests ───────────────────────────────────────────────────────────

def near (a : F64) (b : F64) : Bool := f64_abs (a - b) < 0.000001

#[test]
def test_box_support_picks_the_corner : Bool :=
    let p : Vec3 := support_core (shape_box (vec3 1.0 2.0 3.0)) (vec3 0.5 (0.0 - 1.0) 0.1) in
    near p.x 1.0 && near p.y (0.0 - 2.0) && near p.z 3.0

#[test]
def test_capsule_support_adds_the_margin : Bool :=
    let p : Vec3 := support_world (shape_capsule 0.5 1.0) (pose_at (vec3 0.0 1.0 0.0)) (vec3 0.0 2.0 0.0) in
    near p.y 2.5

#[test]
def test_hull_support_is_the_farthest_point : Bool :=
    let s : Shape := shape_convex [vec3 0.0 0.0 0.0, vec3 1.0 0.0 0.0, vec3 0.0 3.0 0.0] in
    let p : Vec3 := support_core s (vec3 0.0 1.0 0.0) in
    near p.y 3.0

#[test]
def test_rotated_box_aabb_grows : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 0.0 1.0 0.0) 0.7853981633974483 in
    let b : AABB := shape_aabb (shape_box (vec3 1.0 1.0 1.0)) (pose_new v3_zero q) in
    near b.max.x 1.4142135623730951 && near b.max.y 1.0

#[test]
def test_layers_must_meet_both_ways : Bool :=
    let a : Collider := collider_with_layers (collider (shape_sphere 1.0)) 1 2 in
    let b : Collider := collider_with_layers (collider (shape_sphere 1.0)) 2 1 in
    let c : Collider := collider_with_layers (collider (shape_sphere 1.0)) 2 2 in
    layers_interact a b && Bool.not (layers_interact a c)

#[test]
def test_pose_round_trips_points : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 1.0 1.0 0.0) 1.1 in
    let x : Pose := pose_new (vec3 1.0 2.0 3.0) q in
    let p : Vec3 := pose_inv_point x (pose_point x (vec3 0.3 (0.0 - 0.2) 0.9)) in
    near p.x 0.3 && near p.y (0.0 - 0.2) && near p.z 0.9
