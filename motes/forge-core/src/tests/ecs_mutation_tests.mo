// despawn / insert_component / remove_component over the public surface.

use lib::ecs {
    Entity, World, Spawned, spawn, empty_world,
    despawn, insert_component, remove_component,
    world_archetype_count, world_free_ids, components_of
}

def has_pos : Spawned :=
    spawn empty_world [Pair.pair "pos" (Any.any 1u64)]

#[test]
def test_despawn_frees_id_with_bumped_generation : Bool :=
    let spawned : Spawned := has_pos in
    let world : World := despawn spawned.world spawned.entity in
    match List.first (world_free_ids world) {
        Option.some slot => U64.beq slot.generation (U64.add spawned.entity.generation 1u64),
        Option.none => false
    }

#[test]
def test_insert_component_migrates_to_new_archetype : Bool :=
    let spawned : Spawned := has_pos in
    let world : World := insert_component spawned.world spawned.entity "vel" (Any.any 2u64) in
    I64.beq (world_archetype_count world) 2

#[test]
def test_insert_component_keeps_old_archetype_for_a_second_entity : Bool :=
    let spawned : Spawned := has_pos in
    let two : Spawned := spawn spawned.world [Pair.pair "pos" (Any.any 3u64)] in
    let world : World := insert_component two.world spawned.entity "vel" (Any.any 2u64) in
    I64.beq (world_archetype_count world) 2

#[test]
def test_remove_component_shrinks_the_row : Bool :=
    let spawned : Spawned := has_pos in
    let with_vel : World := insert_component spawned.world spawned.entity "vel" (Any.any 2u64) in
    let world : World := remove_component with_vel spawned.entity "vel" in
    I64.beq (List.length (components_of world spawned.entity)) 1

#[test]
def test_despawn_removes_the_entity : Bool :=
    let spawned : Spawned := has_pos in
    let world : World := despawn spawned.world spawned.entity in
    I64.beq (List.length (components_of world spawned.entity)) 0
