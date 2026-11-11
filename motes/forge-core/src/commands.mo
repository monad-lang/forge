// Deferred World edits: a `Commands` handle queues `Command`s into a
// `CommandBuffer`, which `flush` applies to a `World` in order. Lets a
// "system" describe edits without taking `World` by value itself.

use lib::ecs {Entity, World, Spawned, spawn, despawn, insert_component, remove_component}

pub type Command {
    spawn_cmd (components : List (Pair String Any)),
    despawn_cmd (entity : Entity),
    insert_cmd (entity : Entity) (key : String) (value : Any),
    remove_cmd (entity : Entity) (key : String)
}

pub struct CommandBuffer {
    commands : List Command
}

pub def empty_buffer : CommandBuffer := { commands := [] : CommandBuffer }

pub struct Commands {
    buffer : CommandBuffer
}

pub def empty_commands : Commands := { buffer := empty_buffer : Commands }

pub def commands_spawn (cmds : Commands) (components : List (Pair String Any)) : Commands :=
    let pending := cmds.buffer.commands in
    { buffer := { commands := List.append pending [Command.spawn_cmd components] : CommandBuffer } : Commands }

pub def commands_despawn (cmds : Commands) (entity : Entity) : Commands :=
    let pending := cmds.buffer.commands in
    { buffer := { commands := List.append pending [Command.despawn_cmd entity] : CommandBuffer } : Commands }

pub def commands_insert (cmds : Commands) (entity : Entity) (key : String) (value : Any) : Commands :=
    let pending := cmds.buffer.commands in
    { buffer := { commands := List.append pending [Command.insert_cmd entity key value] : CommandBuffer } : Commands }

pub def commands_remove (cmds : Commands) (entity : Entity) (key : String) : Commands :=
    let pending := cmds.buffer.commands in
    { buffer := { commands := List.append pending [Command.remove_cmd entity key] : CommandBuffer } : Commands }

def apply_command (world : World) (cmd : Command) : World :=
    match cmd {
        spawn_cmd components =>
            let spawned : Spawned := spawn world components in
            spawned.world,
        despawn_cmd entity => despawn world entity,
        insert_cmd entity key value => insert_component world entity key value,
        remove_cmd entity key => remove_component world entity key
    }

#[terminating]
pub def flush (world : World) (buffer : CommandBuffer) : World :=
    match buffer.commands {
        List.empty => world,
        List.cons cmd rest => flush (apply_command world cmd) { commands := rest : CommandBuffer }
    }

pub def flush_commands (world : World) (cmds : Commands) : World :=
    flush world cmds.buffer
