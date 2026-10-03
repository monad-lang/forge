// forge-core: ECS (Entity, Archetype, ComponentStorage, World), Commands,
// and Query. Phase 1b + Phase 2, see ../../../PLAN.md.

pub use lib::ecs {
    Entity, entity_id, entity_beq,
    Archetype, ComponentStorage, World, empty_world,
    spawn, despawn, insert_component, remove_component,
    changed_since
}
pub use lib::commands {
    Command, CommandBuffer, Commands,
    empty_buffer, empty_commands,
    commands_spawn, commands_despawn, commands_insert, commands_remove,
    flush, flush_commands
}
pub use lib::query {
    Query, query_iter, ChangedFilter, passes_changed_filter
}
