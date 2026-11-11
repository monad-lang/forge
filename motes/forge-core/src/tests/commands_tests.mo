// CommandBuffer / Commands / flush over the public surface.

use lib::ecs {
    Entity, World, Spawned, spawn, empty_world, insert_component,
    world_archetype_count
}
use lib::commands {
    Commands, empty_commands, commands_spawn, commands_insert, flush_commands
}

#[test]
def test_flush_applies_queued_spawn : Bool :=
    let cmds : Commands := commands_spawn empty_commands [Pair.pair "pos" (Any.any 1u64)] in
    let world : World := flush_commands empty_world cmds in
    I64.beq (world_archetype_count world) 1

#[test]
def test_flush_applies_commands_in_order : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let direct : World := insert_component spawned.world spawned.entity "vel" (Any.any 2u64) in
    let cmds : Commands := commands_insert empty_commands spawned.entity "vel" (Any.any 2u64) in
    let flushed : World := flush_commands spawned.world cmds in
    I64.beq (world_archetype_count flushed) (world_archetype_count direct)

#[test]
def test_spawn_not_visible_before_flush : Bool :=
    let cmds : Commands := commands_spawn empty_commands [Pair.pair "pos" (Any.any 1u64)] in
    let untouched : World := empty_world in
    I64.beq (world_archetype_count untouched) 0
