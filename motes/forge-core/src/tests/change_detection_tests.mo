// changed_since / passes_changed_filter over the public surface.

use lib::ecs {
    Entity, World, Spawned, ComponentId, spawn, empty_world, insert_component,
    changed_since, changed_since_named, lookup_component, world_clock, world_registry
}
use lib::query {ChangedFilter, passes_changed_filter}

#[test]
def test_changed_since_fires_after_write : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let before : U64 := world_clock spawned.world in
    let world : World := insert_component spawned.world spawned.entity "pos" (Any.any 2u64) in
    changed_since_named world spawned.entity "pos" before

#[test]
def test_changed_since_false_for_untouched_component : Bool :=
    let spawned : Spawned :=
        spawn empty_world [Pair.pair "pos" (Any.any 1u64), Pair.pair "vel" (Any.any 2u64)] in
    let after : U64 := world_clock spawned.world in
    let world : World := insert_component spawned.world spawned.entity "vel" (Any.any 9u64) in
    Bool.not (changed_since_named world spawned.entity "pos" after)

#[test]
def test_passes_changed_filter_matches_changed_since : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let before : U64 := world_clock spawned.world in
    let world : World := insert_component spawned.world spawned.entity "pos" (Any.any 2u64) in
    passes_changed_filter world spawned.entity { key := "pos", last_seen := before : ChangedFilter }

#[test]
def test_changed_since_with_interned_id : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let before : U64 := world_clock spawned.world in
    let world : World := insert_component spawned.world spawned.entity "pos" (Any.any 2u64) in
    match lookup_component (world_registry world) "pos" {
        Option.none => false,
        Option.some c => changed_since world spawned.entity c before
    }
