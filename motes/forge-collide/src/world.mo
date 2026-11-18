// forge-collide: the collision scene (every collider in a world, posed and
// bounded once per query batch) and the broad phase.
//
// The broad phase is sort-and-sweep on x: sort by each box's min x, then
// compare every entry only with the ones after it whose min x is not past
// its max x. Planes are infinite, so they skip the sweep and pair with every
// other collider. Layers filter pairs before the narrow phase sees them.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, entity_id, entity_gen}
use forge_core::query {query_entities}
use forge_math {Vec3, AABB, aabb_intersects_aabb}
use forge_scene {transform_name}
use lib::shape {
    Shape, Pose, Collider, collider_name, entity_collider, entity_pose, collider_pose,
    shape_aabb, shape_is_plane, layers_interact
}

// ── Entries ─────────────────────────────────────────────────────────

/// One posed collider. `Copy` (identity: persistent fields).
pub struct Entry {
    entity : Entity,
    collider : Collider,
    pose : Pose,
    bounds : AABB
}

pub instance Copy Entry {
    def copy (e : Entry) : Pair Entry Entry := Pair.pair e e
}

pub def entry_entity (e : Entry) : Entity := e.entity

pub def entry_collider (e : Entry) : Collider := e.collider

pub def entry_pose (e : Entry) : Pose := e.pose

pub def entry_bounds (e : Entry) : AABB := e.bounds

pub def entry_shape (e : Entry) : Shape := e.collider.shape

pub def entry_is_trigger (e : Entry) : Bool := e.collider.is_trigger

pub def entry_is_plane (e : Entry) : Bool := shape_is_plane e.collider.shape

pub def same_entity (a : Entity) (b : Entity) : Bool :=
    entity_id a == entity_id b && entity_gen a == entity_gen b

/// Every collider of a world, posed for this frame. `Copy`, so a batch of
/// queries (a controller step) gathers it once.
pub struct Scene {
    entries : List Entry
}

pub instance Copy Scene {
    def copy (s : Scene) : Pair Scene Scene := Pair.pair s s
}

pub def scene_entries (s : Scene) : List Entry := s.entries

pub def scene_size (s : Scene) : I64 := List.length s.entries

def entry_of (world : World) (e : Entity) (c : Collider) : Entry :=
    let x : Pose := collider_pose c (entity_pose world e) in
    { entity := e, collider := c, pose := x, bounds := shape_aabb c.shape x : Entry }

#[terminating]
def gather (world : World) (es : List Entity) (acc : List Entry) : List Entry :=
    match es {
        List.empty => acc,
        List.cons e rest =>
            match entity_collider world e {
                Option.some c => gather world rest (List.cons (entry_of world e c) acc),
                Option.none => gather world rest acc
            }
    }

/// The world's colliders (entities with a `Collider` and a `Transform`).
pub def collision_scene (world : World) : Scene :=
    { entries := gather world (query_entities world [collider_name, transform_name] []) [] : Scene }

/// A scene from explicit entries (tests, or colliders not in a world).
pub def scene_of (entries : List Entry) : Scene := { entries := entries : Scene }

pub def entry_new (e : Entity) (c : Collider) (x : Pose) : Entry :=
    { entity := e, collider := c, pose := x, bounds := shape_aabb c.shape x : Entry }

// ── Pairs ───────────────────────────────────────────────────────────

/// A candidate pair, ordered so `a` has the smaller entity id. `Copy`.
pub struct Candidate {
    a : Entry,
    b : Entry
}

pub instance Copy Candidate {
    def copy (c : Candidate) : Pair Candidate Candidate := Pair.pair c c
}

pub def candidate_a (c : Candidate) : Entry := c.a

pub def candidate_b (c : Candidate) : Entry := c.b

def candidate (x : Entry) (y : Entry) : Candidate :=
    if entity_id x.entity < entity_id y.entity
    then { a := x, b := y : Candidate }
    else { a := y, b := x : Candidate }

def admits (x : Entry) (y : Entry) : Bool :=
    Bool.not (same_entity x.entity y.entity)
        && layers_interact x.collider y.collider
        && Bool.not (entry_is_plane x && entry_is_plane y)

// ── Merge sort on min x ─────────────────────────────────────────────

struct Halves {
    l : List Entry,
    r : List Entry
}

instance Copy Halves {
    def copy (h : Halves) : Pair Halves Halves := Pair.pair h h
}

#[terminating]
def halve (xs : List Entry) (l : List Entry) (r : List Entry) : Halves :=
    match xs {
        List.empty => { l := l, r := r : Halves },
        List.cons x rest => halve rest r (List.cons x l)
    }

#[terminating]
def merge (xs : List Entry) (ys : List Entry) : List Entry :=
    match xs {
        List.empty => ys,
        List.cons x xr =>
            match ys {
                List.empty => List.cons x xr,
                List.cons y yr =>
                    if x.bounds.min.x <= y.bounds.min.x
                    then List.cons x (merge xr (List.cons y yr))
                    else List.cons y (merge (List.cons x xr) yr)
            }
    }

#[terminating]
def sort_go (xs : List Entry) (n : I64) : List Entry :=
    if n < 2 then xs
    else
        let h : Halves := halve xs [] [] in
        merge (sort_go h.l (List.length h.l)) (sort_go h.r (List.length h.r))

/// Entries by increasing min x.
pub def sort_by_min_x (xs : List Entry) : List Entry :=
    let s : Scene := { entries := xs : Scene } in
    sort_go s.entries (List.length s.entries)

// ── Sweep ───────────────────────────────────────────────────────────

/// Pairs of `x` with the following entries that start before it ends.
#[terminating]
def sweep_one (x : Entry) (ys : List Entry) (acc : List Candidate) : List Candidate :=
    match ys {
        List.empty => acc,
        List.cons y rest =>
            if y.bounds.min.x > x.bounds.max.x then acc
            else if admits x y && aabb_intersects_aabb x.bounds y.bounds
            then sweep_one x rest (List.cons (candidate x y) acc)
            else sweep_one x rest acc
    }

/// The sorted entries are `Copy`-wrapped, so each step can both read its
/// head's followers and recurse on them.
#[terminating]
def sweep (s : Scene) (acc : List Candidate) : List Candidate :=
    match s.entries {
        List.empty => acc,
        List.cons x rest =>
            let tail : Scene := { entries := rest : Scene } in
            sweep tail (sweep_one x tail.entries acc)
    }

#[terminating]
def split_planes (xs : List Entry) (planes : List Entry) (solids : List Entry) : Halves :=
    match xs {
        List.empty => { l := planes, r := solids : Halves },
        List.cons x rest =>
            if entry_is_plane x then split_planes rest (List.cons x planes) solids
            else split_planes rest planes (List.cons x solids)
    }

#[terminating]
def plane_with_all (p : Entry) (ys : List Entry) (acc : List Candidate) : List Candidate :=
    match ys {
        List.empty => acc,
        List.cons y rest =>
            if admits p y then plane_with_all p rest (List.cons (candidate p y) acc)
            else plane_with_all p rest acc
    }

struct Solids {
    xs : List Entry
}

instance Copy Solids {
    def copy (s : Solids) : Pair Solids Solids := Pair.pair s s
}

#[terminating]
def planes_go (ps : List Entry) (solids : Solids) (acc : List Candidate) : List Candidate :=
    match ps {
        List.empty => acc,
        List.cons p rest => planes_go rest solids (plane_with_all p solids.xs acc)
    }

/// The broad phase: every pair whose boxes overlap and whose layers meet.
pub def broad_phase (s : Scene) : List Candidate :=
    let h : Halves := split_planes s.entries [] [] in
    let solids : Solids := { xs := sort_by_min_x h.r : Solids } in
    planes_go h.l solids (sweep { entries := solids.xs : Scene } [])

/// Every admitted pair with overlapping boxes, by brute force (the
/// reference the tests hold `broad_phase` to).
#[terminating]
def brute_go (s : Scene) (acc : List Candidate) : List Candidate :=
    match s.entries {
        List.empty => acc,
        List.cons x rest =>
            let tail : Scene := { entries := rest : Scene } in
            brute_go tail (brute_one x tail.entries acc)
    }

#[terminating]
def brute_one (x : Entry) (ys : List Entry) (acc : List Candidate) : List Candidate :=
    match ys {
        List.empty => acc,
        List.cons y rest =>
            let ok : Bool := admits x y
                && (entry_is_plane x || entry_is_plane y || aabb_intersects_aabb x.bounds y.bounds) in
            if ok then brute_one x rest (List.cons (candidate x y) acc) else brute_one x rest acc
    }

pub def brute_pairs (s : Scene) : List Candidate := brute_go s []
