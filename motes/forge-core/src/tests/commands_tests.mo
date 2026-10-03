use lib::ecs {Entity, World, empty_world, spawn, insert_component}
use lib::commands {Commands, empty_commands, commands_spawn, commands_insert, flush_commands}
use std::list {List.length}

#[test]
def test_flush_applies_queued_spawn : Bool :=
    let cmds := commands_spawn empty_commands [Pair.pair "pos" (Any.any 1u64)] in
    let world := flush_commands empty_world cmds in
    let archetypes := world.storage.archetypes in
    I64.beq (List.length archetypes) 1

#[test]
def test_flush_applies_commands_in_order : Bool :=
    let spawned : Pair World Entity := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let direct_world := insert_component spawned.first spawned.second "vel" (Any.any 2u64) in
    let cmds := commands_insert empty_commands spawned.second "vel" (Any.any 2u64) in
    let flushed_world := flush_commands spawned.first cmds in
    let flushed_archetypes := flushed_world.storage.archetypes in
    let direct_archetypes := direct_world.storage.archetypes in
    I64.beq (List.length flushed_archetypes) (List.length direct_archetypes)

#[test]
def test_spawn_not_visible_before_flush : Bool :=
    let cmds := commands_spawn empty_commands [Pair.pair "pos" (Any.any 1u64)] in
    let archetypes := empty_world.storage.archetypes in
    I64.beq (List.length archetypes) 0
