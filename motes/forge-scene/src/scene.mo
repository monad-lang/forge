// forge-scene: local transforms, parent/child links, and the top-down
// propagation pass.
//
// `Transform`/`GlobalTransform`/`Parent` are component VALUES, boxed into
// forge-core's `Any` columns and recovered with a typed `let`
// (`match v { Any.any x => let t : Transform := x in t }`) -- the only route
// from `Any` back to a concrete type, since `Any` erases it.
//
// The propagation pass is a pure `World -> World` function (the shape a
// forge-schedule system runs), so it is testable with no IO.
//
// TODO: the children scan is O(n^2) in transformed entities. A
// `HashMap U64 (List U64)` children index, threaded through the recursion,
// would make it linear; correctness is what this phase is for.

use std::derive {derive_copy, derive_clone, derive_debug}
use std::list {List.filter}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {
    Entity, World, Spawned, spawn, insert_component, get_component_named
}
use forge_core::query {query_entities}
use forge_math::{
    Vec3, v3_one, v3_zero, Quat, quat_identity, Mat4, mat4_trs, mat4_mul,
    mat4_translation
}

// ── Component values ────────────────────────────────────────────────

/// Local transform: translation, rotation, scale. `Copy`.
#[derive Copy Clone Debug]
pub struct Transform {
    translation : Vec3,
    rotation : Quat,
    scale : Vec3
}

pub def transform_identity : Transform :=
    { translation := v3_zero, rotation := quat_identity, scale := v3_one : Transform }

pub def transform_new (t : Vec3) (r : Quat) (s : Vec3) : Transform :=
    { translation := t, rotation := r, scale := s : Transform }

/// A translation-only transform.
pub def transform_from_translation (t : Vec3) : Transform :=
    { translation := t, rotation := quat_identity, scale := v3_one : Transform }

/// This transform's local matrix, `T * R * S`.
pub def transform_matrix (t : Transform) : Mat4 :=
    mat4_trs t.translation t.rotation t.scale

pub def transform_translation (t : Transform) : Vec3 := t.translation

/// The parent link. `Copy`.
#[derive Copy Clone Debug]
pub struct Parent {
    entity : Entity
}

pub def parent (e : Entity) : Parent := { entity := e : Parent }

pub def parent_entity (p : Parent) : Entity := p.entity

/// Cached world matrix, recomputed by `propagate_transforms`. `Copy`.
#[derive Copy Clone Debug]
pub struct GlobalTransform {
    matrix : Mat4
}

pub def global_transform (m : Mat4) : GlobalTransform := { matrix := m : GlobalTransform }

pub def global_matrix (g : GlobalTransform) : Mat4 := g.matrix

/// A fresh global for a root: its local matrix.
pub def global_of_local (t : Transform) : GlobalTransform :=
    { matrix := transform_matrix t : GlobalTransform }

// ── Component names ─────────────────────────────────────────────────

pub def transform_name : String := "forge.transform"

pub def global_transform_name : String := "forge.global_transform"

pub def parent_name : String := "forge.parent"

// ── Unboxing ────────────────────────────────────────────────────────
//
// `Any` erases its payload's type; a typed `let` binding is how it comes back.

def as_transform (v : Any) : Transform :=
    match v { Any.any x => let t : Transform := x in t }

def as_global (v : Any) : GlobalTransform :=
    match v { Any.any x => let g : GlobalTransform := x in g }

def as_parent (v : Any) : Parent :=
    match v { Any.any x => let p : Parent := x in p }

// ── Spawning ────────────────────────────────────────────────────────

/// Spawn an entity with a `Transform` and a matching `GlobalTransform`.
pub def spawn_transform (world : World) (t : Transform) : Spawned :=
    let g : GlobalTransform := global_of_local t in
    spawn world [Pair.pair transform_name (Any.any t),
                 Pair.pair global_transform_name (Any.any g)]

/// Spawn an entity with a `Transform` under `parent_entity`.
pub def spawn_transform_child (world : World) (t : Transform) (parent_entity : Entity) : Spawned :=
    let g : GlobalTransform := global_of_local t in
    spawn world [Pair.pair transform_name (Any.any t),
                 Pair.pair global_transform_name (Any.any g),
                 Pair.pair parent_name (Any.any (parent parent_entity))]

/// Spawn a child at a LOCAL offset from `parent_entity`.
pub def spawn_child_at (world : World) (parent_entity : Entity) (offset : Vec3) : Spawned :=
    spawn_transform_child world (transform_from_translation offset) parent_entity

// ── Lookup ──────────────────────────────────────────────────────────

/// An entity's local transform, if it has one.
pub def entity_transform (world : World) (e : Entity) : Option Transform :=
    match get_component_named world e transform_name {
        Option.none => Option.none,
        Option.some v => Option.some (as_transform v)
    }

/// An entity's cached world matrix, if it has one.
pub def entity_global (world : World) (e : Entity) : Option Mat4 :=
    match get_component_named world e global_transform_name {
        Option.none => Option.none,
        Option.some v => Option.some (global_matrix (as_global v))
    }

/// An entity's parent, if it has one.
pub def entity_parent (world : World) (e : Entity) : Option Entity :=
    match get_component_named world e parent_name {
        Option.none => Option.none,
        Option.some v => Option.some (parent_entity (as_parent v))
    }

/// Does `e` carry a `Parent`? (`world_has_component` is NOT this test -- it
/// reports whether the world has ever interned the NAME.)
pub def has_parent (world : World) (e : Entity) : Bool :=
    match get_component_named world e parent_name {
        Option.some _ => true,
        Option.none => false
    }

/// Every entity carrying a `Transform` (via forge-core's query machinery, so
/// no archetype field access is needed across the crate boundary).
pub def all_transformed (world : World) : List Entity :=
    query_entities world [transform_name] []

/// The transformed entities with no parent -- where propagation starts.
pub def transform_roots (world : World) : List Entity :=
    List.filter (fn (e : Entity) => Bool.not (has_parent world e)) (all_transformed world)

/// The transformed children of `parent_e`.
pub def children_of (world : World) (parent_e : Entity) : List Entity :=
    List.filter
        (fn (e : Entity) =>
            match entity_parent world e {
                Option.none => false,
                Option.some pe => U64.beq pe.id parent_e.id
            })
        (all_transformed world)

// ── Propagation ─────────────────────────────────────────────────────
//
// Top-down depth-first: a root's global is its local; a child's global is
// `parent_global * local`. Starting at the roots means a parent is always
// written before its children are read.
//
// `#[terminating]` is load-bearing: the recursion descends into a FILTERED
// child list, not a structural subterm, so the checker cannot see the
// decrease. (A cyclic parent graph would therefore loop; component chains are
// assumed acyclic, as in every ECS.)

def global_for (world : World) (e : Entity) (local : Transform) : Mat4 :=
    let local_m : Mat4 := transform_matrix local in
    match entity_parent world e {
        Option.none => local_m,
        Option.some pe =>
            match entity_global world pe {
                Option.none => local_m,
                Option.some pg => mat4_mul pg local_m
            }
    }

#[terminating]
def prop_one (world : World) (e : Entity) : World :=
    match entity_transform world e {
        Option.none => world,
        Option.some local =>
            let g : Mat4 := global_for world e local in
            let world1 : World :=
                insert_component world e global_transform_name (Any.any (global_transform g)) in
            prop_forest world1 (children_of world1 e)
    }

#[terminating]
def prop_forest (world : World) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest => prop_forest (prop_one world e) rest
    }

/// Recompute every `GlobalTransform`, top-down from the roots.
pub def propagate_transforms (world : World) : World :=
    prop_forest world (transform_roots world)

/// Convenience: an entity's world-space translation (the global matrix's
/// translation column), if it has a global.
pub def entity_global_translation (world : World) (e : Entity) : Option Vec3 :=
    match entity_global world e {
        Option.none => Option.none,
        Option.some m => Option.some (mat4_translation m)
    }
