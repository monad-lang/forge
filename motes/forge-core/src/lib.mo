// forge-core: ECS (Entity, ComponentId, Column, Archetype, ComponentStorage,
// World), deferred edits (Command/CommandBuffer/Commands), and Query. Phase 1
// + Phase 2, see ../../../PLAN.md.

pub use lib::ecs {
    Entity, entity_id, entity_gen, entity_new,
    ComponentId, component_id, component_id_new,
    Loc, loc_new, Freed,
    ComponentRegistry, empty_registry, intern, Interned, InternedAll, intern_all,
    lookup_component, name_of, registry_len,
    Column, empty_column, column_len, column_get, column_push, Pushed,
    archetype_key, ids_key, sorted_ids, sort_ids,
    Archetype, empty_archetype, archetype_ids, archetype_rows, archetype_column,
    archetype_has_all, has_id, archetype_append_row, archetype_truncate,
    archetype_swap_remove, RemoveResult, Moved, archetype_row_pairs,
    ComponentStorage, empty_storage,
    world_clock, world_registry, world_entity_count, world_archetype_count,
    world_free_ids, world_has_component, world_archetype_ids,
    World, empty_world,
    Spawned, spawn, despawn,
    set_component, SetResult, insert_component, remove_component,
    entity_exists, entity_location, entity_row, archetype_at, archetype_of,
    entity_pairs, components_of, get_component, get_component_named, has_component,
    ids_of_names, archetype_row_count,
    mark_changed, changed_since, last_changed_at, changed_since_named
}

pub use lib::commands {
    Command, CommandBuffer, Commands,
    empty_buffer, empty_commands,
    commands_spawn, commands_despawn, commands_insert, commands_remove,
    flush, flush_commands
}

pub use lib::query {
    Query, query_new, query_required, query_entities, query_iter, row_select,
    ChangedFilter, passes_changed_filter
}

pub use lib::world_m {
    WorldM, WorldM.run, WorldM.run_state, WorldM.get, WorldM.put, WorldM.modify,
    WorldM.lift, PureWorld, PureWorld.run,
    AppWorld, AppWorld.run, FallibleWorld, FallibleWorld.run, FallibleWorld.fail,
    FallibleWorld.of_result, FallibleWorld.lift, FallibleWorld.get, FallibleWorld.modify
}
