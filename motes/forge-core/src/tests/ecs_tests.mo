use lib::ecs {Entity, World, empty_world, spawn}
use std::list {List.length}

def has_pos : Pair World Entity :=
    spawn empty_world [Pair.pair "pos" (Any.any 1u64)]

#[test]
def test_spawn_lands_in_matching_archetype : Bool :=
    let result : Pair World Entity := has_pos in
    let world := result.first in
    let archetypes := world.storage.archetypes in
    I64.beq (List.length archetypes) 1

#[test]
def test_spawn_assigns_generation_zero : Bool :=
    let result : Pair World Entity := has_pos in
    let entity := result.second in
    U64.beq entity.generation 0u64

#[test]
def test_double_spawn_same_archetype : Bool :=
    let first : Pair World Entity := has_pos in
    let second : Pair World Entity := spawn first.first [Pair.pair "pos" (Any.any 2u64)] in
    let world := second.first in
    let archetypes := world.storage.archetypes in
    I64.beq (List.length archetypes) 1
