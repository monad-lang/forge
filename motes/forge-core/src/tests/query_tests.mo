use lib::ecs {Entity, World, empty_world, spawn}
use lib::query {query_iter}
use lib::commands {empty_commands, commands_spawn, flush_commands}
use std::list {List.length, List.contains_by}

#[test]
def test_query_returns_only_matching_entities : Bool :=
    let with_pos : Pair World Entity := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let with_both : Pair World Entity := spawn with_pos.first [Pair.pair "pos" (Any.any 2u64), Pair.pair "vel" (Any.any 3u64)] in
    let results := query_iter with_both.first ["vel"] [] in
    I64.beq (List.length results) 1

#[test]
def test_query_result_carries_requested_components : Bool :=
    let spawned : Pair World Entity := spawn empty_world [Pair.pair "pos" (Any.any 1u64), Pair.pair "vel" (Any.any 2u64)] in
    let results := query_iter spawned.first ["pos"] [] in
    match List.first results {
        Option.some row => List.contains_by String.beq "pos" (List.map (fn (kv : Pair String Any) => kv.first) row.second),
        Option.none => false
    }

#[test]
def test_command_flush_ordering_visible_to_query : Bool :=
    let cmds := commands_spawn empty_commands [Pair.pair "pos" (Any.any 1u64)] in
    let not_yet := query_iter empty_world ["pos"] [] in
    let world := flush_commands empty_world cmds in
    let after_flush := query_iter world ["pos"] [] in
    I64.beq (List.length not_yet) 0 && I64.beq (List.length after_flush) 1
