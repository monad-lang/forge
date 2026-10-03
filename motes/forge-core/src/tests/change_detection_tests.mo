// changed_since / passes_changed_filter tests.
//
// Blocked by the same toolchain bug as ecs_mutation_tests.mo (all three
// call insert_component). See that file's header and
// plans-monad/implementations/2026-10-03-any-boxed-struct-reconstruction-corrupts-sibling-field.md.
// Kept in their own file so the crash doesn't take down query_tests.mo's
// passing tests.

use lib::ecs {Entity, World, empty_world, spawn, insert_component, changed_since}
use lib::query {ChangedFilter, passes_changed_filter}

#[test]
def test_changed_since_fires_after_write : Bool :=
    let spawned : Pair World Entity := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let before_tick := spawned.first.storage.clock in
    let world := insert_component spawned.first spawned.second "pos" (Any.any 2u64) in
    changed_since world spawned.second "pos" before_tick

#[test]
def test_changed_since_false_for_untouched_component : Bool :=
    let spawned : Pair World Entity := spawn empty_world [Pair.pair "pos" (Any.any 1u64), Pair.pair "vel" (Any.any 2u64)] in
    let after_spawn_tick := spawned.first.storage.clock in
    let world := insert_component spawned.first spawned.second "vel" (Any.any 9u64) in
    Bool.not (changed_since world spawned.second "pos" after_spawn_tick)

#[test]
def test_passes_changed_filter_matches_changed_since : Bool :=
    let spawned : Pair World Entity := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let before_tick := spawned.first.storage.clock in
    let world := insert_component spawned.first spawned.second "pos" (Any.any 2u64) in
    passes_changed_filter world spawned.second { key := "pos", last_seen := before_tick : ChangedFilter }
