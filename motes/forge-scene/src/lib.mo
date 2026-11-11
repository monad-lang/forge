// forge-scene: local transforms, parent/child links, and top-down propagation.
// Phase 5, see ../../../PLAN.md.
//
// The propagation pass is a pure `World -> World` function, so it slots into a
// forge-schedule system directly. Component values are boxed into the ECS as
// `Any`; this module owns the typed accessors (`entity_transform`,
// `entity_global`, `entity_parent`) that unbox them.

pub use lib::scene {
    Transform, transform_identity, transform_new, transform_from_translation,
    transform_matrix, transform_translation,
    Parent, parent, parent_entity,
    GlobalTransform, global_transform, global_matrix, global_of_local,
    transform_name, global_transform_name, parent_name,
    spawn_transform, spawn_transform_child, spawn_child_at,
    entity_transform, entity_global, entity_parent, has_parent,
    all_transformed, transform_roots, children_of,
    propagate_transforms, entity_global_translation
}
