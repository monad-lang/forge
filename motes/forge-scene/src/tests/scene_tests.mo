// forge-scene integration tests, over the PUBLIC surface (`lib::{...}`).
//
// These spawn hierarchies, run the pure propagation pass, and read the cached
// world matrices back. `f64_approx` (forge-math's `num`) is used for the float
// compares; everything here is exact enough for a 1e-4 tolerance.

use lib::{
    Transform, transform_identity, transform_from_translation,
    spawn_transform, spawn_transform_child, spawn_child_at,
    entity_transform, entity_global, entity_parent, entity_global_translation,
    all_transformed, transform_roots, children_of, propagate_transforms,
    transform_name, parent_name
}
use forge_core::ecs {
    Entity, World, Spawned, spawn, empty_world, despawn, insert_component,
    world_entity_count, world_has_component
}
use forge_math::{
    Vec3, vec3, v3_dot, v3_sub, v3_distance,
    Quat, quat_identity,
    mat4_transform_point, mat4_identity, Mat4
}

// `f64_abs` is in forge-math's private `num`; re-state the tiny compare here
// rather than widening forge-math's public surface for a test helper.
def approx (a : F64) (b : F64) : Bool :=
    let d : F64 := a - b in
    let ad : F64 := if d < 0.0 then 0.0 - d else d in
    ad < 0.0001

def v3_approx (a : Vec3) (b : Vec3) : Bool :=
    v3_distance a b < 0.0001

#[test]
def test_spawn_transform_attaches_both_components : Bool :=
    let s : Spawned := spawn_transform empty_world (transform_from_translation (vec3 1.0 2.0 3.0)) in
    world_has_component s.world transform_name

#[test]
def test_root_global_equals_local : Bool :=
    let s : Spawned := spawn_transform empty_world (transform_from_translation (vec3 4.0 5.0 6.0)) in
    let world : World := propagate_transforms s.world in
    match entity_global_translation world s.entity {
        Option.some t => v3_approx t (vec3 4.0 5.0 6.0),
        Option.none => false
    }

#[test]
def test_child_global_is_parent_plus_local : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 10.0 0.0 0.0)) in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 2.0 0.0) in
    let world : World := propagate_transforms child.world in
    match entity_global_translation world child.entity {
        Option.some t => v3_approx t (vec3 11.0 2.0 0.0),
        Option.none => false
    }

#[test]
def test_grandchild_accumulates_the_whole_chain : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 1.0 0.0 0.0)) in
    let mid : Spawned := spawn_child_at root.world root.entity (vec3 2.0 0.0 0.0) in
    let leaf : Spawned := spawn_child_at mid.world mid.entity (vec3 3.0 0.0 0.0) in
    let world : World := propagate_transforms leaf.world in
    match entity_global_translation world leaf.entity {
        Option.some t => v3_approx t (vec3 6.0 0.0 0.0),
        Option.none => false
    }

#[test]
def test_child_local_offset_does_not_move_the_parent : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 5.0 5.0 5.0)) in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    let world : World := propagate_transforms child.world in
    match entity_global_translation world root.entity {
        Option.some t => v3_approx t (vec3 5.0 5.0 5.0),
        Option.none => false
    }

#[test]
def test_two_children_both_get_globals : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 1.0 1.0 1.0)) in
    let c1 : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    let c2 : Spawned := spawn_child_at c1.world root.entity (vec3 0.0 1.0 0.0) in
    let world : World := propagate_transforms c2.world in
    let g1 : Bool := match entity_global_translation world c1.entity {
        Option.some t => v3_approx t (vec3 2.0 1.0 1.0),
        Option.none => false
    } in
    let g2 : Bool := match entity_global_translation world c2.entity {
        Option.some t => v3_approx t (vec3 1.0 2.0 1.0),
        Option.none => false
    } in
    g1 && g2

#[test]
def test_children_of_finds_one_child : Bool :=
    let root : Spawned := spawn_transform empty_world transform_identity in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    I64.beq (List.length (children_of child.world root.entity)) 1

#[test]
def test_transform_roots_excludes_children : Bool :=
    let root : Spawned := spawn_transform empty_world transform_identity in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    // Two transformed entities, one of them a child -> one root.
    I64.beq (List.length (all_transformed child.world)) 2
        && I64.beq (List.length (transform_roots child.world)) 1

#[test]
def test_entity_parent_reads_back : Bool :=
    let root : Spawned := spawn_transform empty_world transform_identity in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    match entity_parent child.world child.entity {
        Option.some pe => U64.beq pe.id root.entity.id,
        Option.none => false
    }

#[test]
def test_despawned_child_leaves_the_root_standing : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 1.0 0.0 0.0)) in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    let world : World := propagate_transforms (despawn child.world child.entity) in
    match entity_global_translation world root.entity {
        Option.some t => v3_approx t (vec3 1.0 0.0 0.0),
        Option.none => false
    }

#[test]
def test_propagation_is_idempotent : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 3.0 0.0 0.0)) in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    let once : World := propagate_transforms child.world in
    let twice : World := propagate_transforms once in
    match entity_global_translation twice child.entity {
        Option.some t => v3_approx t (vec3 4.0 0.0 0.0),
        Option.none => false
    }

#[test]
def test_moving_the_parent_moves_the_child_next_pass : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 0.0 0.0 0.0)) in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    let world1 : World := propagate_transforms child.world in
    // Move the root, then propagate again.
    let moved : World :=
        insert_component world1 root.entity transform_name
            (Any.any (transform_from_translation (vec3 10.0 0.0 0.0))) in
    let world2 : World := propagate_transforms moved in
    match entity_global_translation world2 child.entity {
        Option.some t => v3_approx t (vec3 11.0 0.0 0.0),
        Option.none => false
    }

#[test]
def test_scale_propagates_into_the_child_translation : Bool :=
    // A parent scaled by 2 puts a child with local offset (1,0,0) at (2,0,0).
    let root_t : Transform :=
        { translation := vec3 0.0 0.0 0.0, rotation := quat_identity,
          scale := vec3 2.0 2.0 2.0 : Transform } in
    let root : Spawned := spawn_transform empty_world root_t in
    let child : Spawned := spawn_child_at root.world root.entity (vec3 1.0 0.0 0.0) in
    let world : World := propagate_transforms child.world in
    match entity_global_translation world child.entity {
        Option.some t => v3_approx t (vec3 2.0 0.0 0.0),
        Option.none => false
    }

// ── A wide, deep hierarchy (the child index) ────────────────────────
//
// One root at x = 1, with `n` children each offset by x = 1, each of which
// has a grandchild offset by y = 1. Propagation reads the hierarchy from an
// index built in one pass; this checks every sibling and every grandchild is
// still reached, not just the first.

#[terminating]
def add_branches (world : World) (root : Entity) (n : I64) : World :=
    if I64.lt 0 n
    then
        let child : Spawned := spawn_child_at world root (vec3 1.0 0.0 0.0) in
        let grand : Spawned := spawn_child_at child.world child.entity (vec3 0.0 1.0 0.0) in
        add_branches grand.world root (I64.sub n 1)
    else world

#[terminating]
def count_at (world : World) (es : List Entity) (want : Vec3) (n : I64) : I64 :=
    match es {
        List.empty => n,
        List.cons e rest =>
            match entity_global_translation world e {
                Option.some t => count_at world rest want (if v3_approx t want then I64.add n 1 else n),
                Option.none => count_at world rest want n
            }
    }

#[test]
def test_wide_hierarchy_reaches_every_sibling_and_grandchild : Bool :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 1.0 0.0 0.0)) in
    let world : World := propagate_transforms (add_branches root.world root.entity 6) in
    // 1 root + 6 children at (2,0,0) + 6 grandchildren at (2,1,0).
    I64.beq (world_entity_count world) 13
        && I64.beq (count_at world (all_transformed world) (vec3 2.0 0.0 0.0) 0) 6
        && I64.beq (count_at world (all_transformed world) (vec3 2.0 1.0 0.0) 0) 6
        && I64.beq (count_at world (all_transformed world) (vec3 1.0 0.0 0.0) 0) 1

#[test]
def test_two_roots_propagate_independently : Bool :=
    let a : Spawned := spawn_transform empty_world (transform_from_translation (vec3 10.0 0.0 0.0)) in
    let b : Spawned := spawn_transform a.world (transform_from_translation (vec3 0.0 20.0 0.0)) in
    let ca : Spawned := spawn_child_at b.world a.entity (vec3 1.0 0.0 0.0) in
    let cb : Spawned := spawn_child_at ca.world b.entity (vec3 1.0 0.0 0.0) in
    let world : World := propagate_transforms cb.world in
    I64.beq (count_at world (all_transformed world) (vec3 11.0 0.0 0.0) 0) 1
        && I64.beq (count_at world (all_transformed world) (vec3 1.0 20.0 0.0) 0) 1
