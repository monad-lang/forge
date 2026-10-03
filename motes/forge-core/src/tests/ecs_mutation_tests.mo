// despawn / insert_component / remove_component tests.
//
// These are written to the correct, intended behavior and are NOT expected
// to pass right now: a confirmed toolchain bug corrupts a sibling field's
// list whenever World/ComponentStorage is reconstructed from a world that
// already holds an Any-boxed Archetype (which every one of these does,
// since they all operate on a world that has already been spawned into).
// Kept in their own file so this toolchain crash (not just a test
// failure -- `monad test` aborts the whole binary) doesn't take down the
// passing spawn tests in ecs_tests.mo, which share a binary with whatever
// else is in their own file.
//
// Repro + writeup: plans-monad/implementations/2026-10-03-any-boxed-struct-reconstruction-corrupts-sibling-field.md
// Delete this comment and expect these green once that's fixed upstream.

use lib::ecs {Entity, World, empty_world, spawn, despawn, insert_component, remove_component}
use std::list {List.length, List.filter}

def has_pos : Pair World Entity :=
    spawn empty_world [Pair.pair "pos" (Any.any 1u64)]

#[test]
def test_despawn_bumps_generation_and_frees_id : Bool :=
    let spawned : Pair World Entity := has_pos in
    let world := despawn spawned.first spawned.second in
    let entity := spawned.second in
    let free_ids := world.storage.free_ids in
    match List.first (List.filter (fn (p : Pair U64 U64) => U64.beq p.first entity.id) free_ids) {
        Option.some slot => U64.beq slot.second (U64.add entity.generation 1u64),
        Option.none => false
    }

#[test]
def test_insert_component_migrates_to_new_archetype : Bool :=
    let spawned : Pair World Entity := has_pos in
    let world := insert_component spawned.first spawned.second "vel" (Any.any 2u64) in
    let archetypes := world.storage.archetypes in
    I64.beq (List.length archetypes) 1

#[test]
def test_insert_component_keeps_old_archetype_when_two_entities_diverge : Bool :=
    let spawned : Pair World Entity := has_pos in
    let world_with_two : Pair World Entity := spawn spawned.first [Pair.pair "pos" (Any.any 3u64)] in
    let world := insert_component world_with_two.first spawned.second "vel" (Any.any 2u64) in
    let archetypes := world.storage.archetypes in
    I64.beq (List.length archetypes) 2

#[test]
def test_remove_component_migrates_back : Bool :=
    let spawned : Pair World Entity := has_pos in
    let with_vel := insert_component spawned.first spawned.second "vel" (Any.any 2u64) in
    let world := remove_component with_vel spawned.second "vel" in
    let archetypes := world.storage.archetypes in
    I64.beq (List.length archetypes) 1
