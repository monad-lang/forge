// Query iteration over the public surface.

use lib::ecs {
    Entity, World, Spawned, ComponentId, spawn, empty_world, get_component_named,
    world_has_component, ids_of_names
}
use lib::query {query_iter, query_entities, row_select}
use lib::commands {Commands, empty_commands, commands_spawn, flush_commands}

#[test]
def test_query_returns_only_matching_entities : Bool :=
    let with_pos : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let with_both : Spawned :=
        spawn with_pos.world [Pair.pair "pos" (Any.any 2u64), Pair.pair "vel" (Any.any 3u64)] in
    I64.beq (List.length (query_entities with_both.world ["vel"] [])) 1

#[test]
def test_query_result_carries_requested_components : Bool :=
    let spawned : Spawned :=
        spawn empty_world [Pair.pair "pos" (Any.any 1u64), Pair.pair "vel" (Any.any 2u64)] in
    let wanted : List ComponentId := ids_of_names spawned.world ["pos"] in
    match List.first (query_iter spawned.world ["pos"] []) {
        Option.some row => I64.beq (List.length (row_select row.second wanted)) 1,
        Option.none => false
    }

#[test]
def test_command_flush_ordering_visible_to_query : Bool :=
    let cmds : Commands := commands_spawn empty_commands [Pair.pair "pos" (Any.any 1u64)] in
    let before := query_entities empty_world ["pos"] [] in
    let world : World := flush_commands empty_world cmds in
    let after := query_entities world ["pos"] [] in
    I64.beq (List.length before) 0 && I64.beq (List.length after) 1

#[test]
def test_get_component_named_roundtrips : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 7u64)] in
    match get_component_named spawned.world spawned.entity "pos" {
        Option.some _ => true,
        Option.none => false
    }

#[test]
def test_world_has_component_after_spawn : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    world_has_component spawned.world "pos"
