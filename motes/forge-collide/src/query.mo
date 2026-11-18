// forge-collide: scene queries. `raycast` (nearest hit along a ray),
// `overlap` (every collider a posed shape touches), `shape_cast` (how far a
// shape can translate before it touches something) and `penetrations` (what
// a posed shape is pushed out of, and how far).
//
// Rays use exact forms for spheres, boxes and planes. Capsules, hulls and
// every shape cast use conservative advancement: step by the current
// separation, which can never pass through a convex obstacle when the shape
// moves at unit speed, until the gap is under `cast_skin`.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, entity_new}
use forge_math {
    Vec3, vec3, v3_zero, v3_add, v3_sub, v3_scale, v3_neg, v3_dot, v3_length, v3_normalize,
    Ray, ray, ray_at, Sphere, sphere, ray_sphere_hit, AABB, aabb, aabb_intersects_aabb,
    f64_abs, f64_min, f64_max
}
use lib::shape {
    Shape, Pose, pose_at, pose_pos, pose_translate, pose_dir, pose_inv_dir, pose_inv_point,
    shape_sphere, shape_aabb, plane_world, Collider, mask_accepts
}
use lib::narrow {Proximity, proximity, prox_flip}
use lib::world {Scene, Entry, scene_entries, same_entity, entry_is_plane}

// ── Hits ────────────────────────────────────────────────────────────

/// A ray or cast hit: the entity, the distance along the (unit) direction,
/// the contact point and the obstacle's surface normal there.
#[derive Copy Clone]
pub struct Hit {
    entity : Entity,
    t : F64,
    point : Vec3,
    normal : Vec3
}

pub def hit_entity (h : Hit) : Entity := h.entity

pub def hit_t (h : Hit) : F64 := h.t

pub def hit_point (h : Hit) : Vec3 := h.point

pub def hit_normal (h : Hit) : Vec3 := h.normal

def nearest (a : Option Hit) (b : Option Hit) : Option Hit :=
    match a {
        Option.none => b,
        Option.some x0 =>
            let x : Hit := x0 in
            match b {
                Option.none => Option.some x,
                Option.some y0 => let y : Hit := y0 in if y.t < x.t then Option.some y else Option.some x
            }
    }

/// The entity a query ignores (its own collider), if any. `Copy`.
#[derive Copy Clone]
struct Skip {
    on : Bool,
    e : Entity
}

def skip_of (o : Option Entity) (fallback : Entity) : Skip :=
    match o {
        Option.some e => { on := true, e := e : Skip },
        Option.none => { on := false, e := fallback : Skip }
    }

/// Is `e` the excluded entity?
def excluded (skip : Skip) (e : Entity) : Bool := skip.on && same_entity skip.e e

/// A placeholder for "no entity" inside a disabled `Skip`.
def nobody : Entity := entity_new 0u64 0u64

// ── Rays ────────────────────────────────────────────────────────────

/// Ray against a box in its own frame: slab test, with the entering face.
def ray_box (r : Ray) (h : Vec3) (x : Pose) : Option (Pair F64 Vec3) :=
    let o : Vec3 := pose_inv_point x r.origin in
    let d : Vec3 := pose_inv_dir x r.direction in
    let ix : F64 := 1.0 / d.x in
    let iy : F64 := 1.0 / d.y in
    let iz : F64 := 1.0 / d.z in
    let t1x : F64 := ((0.0 - h.x) - o.x) * ix in
    let t2x : F64 := (h.x - o.x) * ix in
    let t1y : F64 := ((0.0 - h.y) - o.y) * iy in
    let t2y : F64 := (h.y - o.y) * iy in
    let t1z : F64 := ((0.0 - h.z) - o.z) * iz in
    let t2z : F64 := (h.z - o.z) * iz in
    let nx : F64 := f64_min t1x t2x in
    let ny : F64 := f64_min t1y t2y in
    let nz : F64 := f64_min t1z t2z in
    let tnear : F64 := f64_max nx (f64_max ny nz) in
    let tfar : F64 := f64_min (f64_max t1x t2x) (f64_min (f64_max t1y t2y) (f64_max t1z t2z)) in
    if tfar < 0.0 || tnear > tfar then Option.none
    else if tnear < 0.0 then Option.some (Pair.pair 0.0 (v3_neg r.direction))
    else
        let ln : Vec3 :=
            if tnear == nx then vec3 (if d.x > 0.0 then 0.0 - 1.0 else 1.0) 0.0 0.0
            else if tnear == ny then vec3 0.0 (if d.y > 0.0 then 0.0 - 1.0 else 1.0) 0.0
            else vec3 0.0 0.0 (if d.z > 0.0 then 0.0 - 1.0 else 1.0) in
        Option.some (Pair.pair tnear (pose_dir x ln))

def cast_skin : F64 := 0.0001

/// Conservative advancement of a point along `r` toward `s`.
#[terminating]
def march (r : Ray) (s : Shape) (x : Pose) (t : F64) (max_t : F64) (n : I64) : Option (Pair F64 Vec3) :=
    if t > max_t || n > 64 then Option.none
    else
        let p : Proximity := proximity s x (shape_sphere 0.0) (pose_at (ray_at r t)) in
        if p.distance < cast_skin
        then Option.some (Pair.pair t (if p.distance <= 0.0 && t == 0.0 then v3_neg r.direction else p.normal))
        else if v3_dot p.normal r.direction >= 0.0 then Option.none
        else march r s x (t + p.distance) max_t (n + 1)

def ray_shape (r : Ray) (s : Shape) (x : Pose) (max_t : F64) : Option (Pair F64 Vec3) :=
    match s {
        Shape.sphere_shape rad =>
            match ray_sphere_hit r (sphere (pose_pos x) rad) {
                Option.some t =>
                    let tt : F64 := t in
                    Option.some (Pair.pair tt (v3_normalize (v3_sub (ray_at r tt) (pose_pos x)))),
                Option.none => Option.none
            },
        Shape.box_shape h => ray_box r h x,
        Shape.plane_shape pn pd =>
            match plane_world pn pd x {
                Pair.pair n0 d0 =>
                    let n : Vec3 := n0 in
                    let d : F64 := d0 in
                    let side : F64 := v3_dot n r.origin + d in
                    let den : F64 := v3_dot n r.direction in
                    if side <= 0.0 then Option.some (Pair.pair 0.0 n)
                    else if den >= 0.0 then Option.none
                    else Option.some (Pair.pair (side / (0.0 - den)) n)
            },
        Shape.capsule_shape _ _ => march r s x 0.0 max_t 0,
        Shape.convex_shape _ => march r s x 0.0 max_t 0
    }

def ray_entry (r : Ray) (max_t : F64) (e : Entry) : Option Hit :=
    match ray_shape r e.collider.shape e.pose max_t {
        Option.some th =>
            match th {
                Pair.pair t0 n0 =>
                    let t : F64 := t0 in
                    if t <= max_t
                    then Option.some { entity := e.entity, t := t, point := ray_at r t, normal := n0 : Hit }
                    else Option.none
            },
        Option.none => Option.none
    }

#[terminating]
def raycast_go (r : Ray) (max_t : F64) (mask : I64) (es : List Entry) (best : Option Hit) : Option Hit :=
    match es {
        List.empty => best,
        List.cons e rest =>
            if Bool.not (mask_accepts mask e.collider) || e.collider.is_trigger
            then raycast_go r max_t mask rest best
            else raycast_go r max_t mask rest (nearest best (ray_entry r max_t e))
    }

/// The nearest solid (non-trigger) collider along `r` (its direction is
/// normalized here) within `max_t`, among colliders whose layer `mask` meets.
pub def raycast (s : Scene) (r0 : Ray) (max_t : F64) (mask : I64) : Option Hit :=
    let r : Ray := ray r0.origin (v3_normalize r0.direction) in
    raycast_go r max_t mask (scene_entries s) Option.none

// ── Overlap ─────────────────────────────────────────────────────────

#[terminating]
def overlap_go (shape : Shape) (x : Pose) (b : AABB) (mask : I64) (skip : Skip)
    (es : List Entry) (acc : List Entity) : List Entity :=
    match es {
        List.empty => acc,
        List.cons e rest =>
            let candidate : Bool := mask_accepts mask e.collider && Bool.not (excluded skip e.entity)
                && (entry_is_plane e || aabb_intersects_aabb b e.bounds) in
            let p : Proximity := proximity shape x e.collider.shape e.pose in
            if candidate && p.distance <= 0.0
            then overlap_go shape x b mask skip rest (List.cons e.entity acc)
            else overlap_go shape x b mask skip rest acc
    }

/// Every collider (triggers included) that `shape` at `x` touches.
pub def overlap (s : Scene) (shape : Shape) (x : Pose) (mask : I64) (skip : Option Entity) : List Entity :=
    overlap_go shape x (shape_aabb shape x) mask (skip_of skip nobody) (scene_entries s) []

// ── Penetrations ────────────────────────────────────────────────────

/// How `shape` must move to leave entity's collider: along `normal` (away
/// from the obstacle) by `depth`.
#[derive Copy Clone]
pub struct Push {
    entity : Entity,
    normal : Vec3,
    depth : F64
}

pub def push_entity (p : Push) : Entity := p.entity

pub def push_normal (p : Push) : Vec3 := p.normal

pub def push_depth (p : Push) : F64 := p.depth

#[terminating]
def pen_go (shape : Shape) (x : Pose) (b : AABB) (mask : I64) (skip : Skip)
    (es : List Entry) (acc : List Push) : List Push :=
    match es {
        List.empty => acc,
        List.cons e rest =>
            let candidate : Bool := mask_accepts mask e.collider && Bool.not e.collider.is_trigger
                && Bool.not (excluded skip e.entity)
                && (entry_is_plane e || aabb_intersects_aabb b e.bounds) in
            if candidate
            then
                let p : Proximity := proximity shape x e.collider.shape e.pose in
                if p.distance < 0.0
                then pen_go shape x b mask skip rest
                         (List.cons { entity := e.entity, normal := v3_neg p.normal, depth := 0.0 - p.distance : Push } acc)
                else pen_go shape x b mask skip rest acc
            else pen_go shape x b mask skip rest acc
    }

/// The solid colliders `shape` at `x` overlaps, with the push out of each.
pub def penetrations (s : Scene) (shape : Shape) (x : Pose) (mask : I64) (skip : Option Entity) : List Push :=
    pen_go shape x (shape_aabb shape x) mask (skip_of skip nobody) (scene_entries s) []

// ── Shape cast ──────────────────────────────────────────────────────

/// Conservative advancement of `shape` from `x` along unit `dir` toward one
/// obstacle.
#[terminating]
def advance (shape : Shape) (x : Pose) (dir : Vec3) (e : Entry) (t : F64) (max_t : F64) (n : I64) : Option Hit :=
    if t > max_t || n > 48 then Option.none
    else
        let p : Proximity := proximity shape (pose_translate x (v3_scale dir t)) e.collider.shape e.pose in
        if v3_dot p.normal dir <= 0.000000001 then Option.none
        else if p.distance < cast_skin
        then Option.some { entity := e.entity, t := t, point := p.pb, normal := v3_neg p.normal : Hit }
        else advance shape x dir e (t + p.distance) max_t (n + 1)

def swept (shape : Shape) (x : Pose) (dir : Vec3) (max_t : F64) : AABB :=
    let a : AABB := shape_aabb shape x in
    let b : AABB := shape_aabb shape (pose_translate x (v3_scale dir max_t)) in
    aabb (vec3 (f64_min a.min.x b.min.x) (f64_min a.min.y b.min.y) (f64_min a.min.z b.min.z))
         (vec3 (f64_max a.max.x b.max.x) (f64_max a.max.y b.max.y) (f64_max a.max.z b.max.z))

#[terminating]
def cast_go (shape : Shape) (x : Pose) (dir : Vec3) (max_t : F64) (b : AABB) (mask : I64)
    (skip : Skip) (es : List Entry) (best : Option Hit) : Option Hit :=
    match es {
        List.empty => best,
        List.cons e rest =>
            let candidate : Bool := mask_accepts mask e.collider && Bool.not e.collider.is_trigger
                && Bool.not (excluded skip e.entity)
                && (entry_is_plane e || aabb_intersects_aabb b e.bounds) in
            if candidate
            then cast_go shape x dir max_t b mask skip rest (nearest best (advance shape x dir e 0.0 max_t 0))
            else cast_go shape x dir max_t b mask skip rest best
    }

/// The first solid collider `shape` touches when moved from `x` along
/// `dir` (normalized here) by up to `max_t`. Only obstacles the motion
/// approaches count: a shape resting on a floor and moving along it does not
/// hit the floor, and one already overlapping an obstacle it moves into hits
/// it at `t = 0` (resolve that with `penetrations`). The normal is the
/// obstacle's, facing the mover.
pub def shape_cast (s : Scene) (shape : Shape) (x : Pose) (dir0 : Vec3) (max_t : F64) (mask : I64)
    (skip : Option Entity) : Option Hit :=
    let dir : Vec3 := v3_normalize dir0 in
    cast_go shape x dir max_t (swept shape x dir max_t) mask (skip_of skip nobody) (scene_entries s) Option.none
