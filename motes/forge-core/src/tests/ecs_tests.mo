// Basic spawn/shape tests over the public forge-core ECS surface.

use lib::ecs {Entity, World, Spawned, spawn, empty_world, world_archetype_count, entity_gen}

def has_pos : Spawned :=
    spawn empty_world [Pair.pair "pos" (Any.any 1u64)]

#[test]
def test_spawn_lands_in_matching_archetype : Bool :=
    I64.beq (world_archetype_count has_pos.world) 1

#[test]
def test_spawn_assigns_generation_zero : Bool :=
    U64.beq (entity_gen has_pos.entity) 0u64

#[test]
def test_double_spawn_same_archetype : Bool :=
    let first : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let second : Spawned := spawn first.world [Pair.pair "pos" (Any.any 2u64)] in
    I64.beq (world_archetype_count second.world) 1

#[test]
def test_distinct_component_sets_get_distinct_archetypes : Bool :=
    let first : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let second : Spawned := spawn first.world [Pair.pair "pos" (Any.any 1u64), Pair.pair "vel" (Any.any 1u64)] in
    I64.beq (world_archetype_count second.world) 2
