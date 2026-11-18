// forge-collide: collision detection. Phase 10, see ../../../PLAN.md.

pub use lib::shape {
    Pose, pose_at, pose_identity, pose_new, pose_from_matrix, pose_pos, pose_with_pos,
    pose_translate, pose_dir, pose_point, pose_inv_dir, pose_inv_point,
    Shape, shape_sphere, shape_box, shape_capsule, shape_plane, shape_convex,
    shape_is_plane, shape_margin, support_core, support_core_world, support_world,
    shape_aabb, plane_world, plane_reach,
    Collider, collider, collider_trigger, collider_with_offset, collider_with_layers,
    collider_shape, collider_offset, collider_layer, collider_mask, collider_is_trigger,
    layer_all, layer_default, layers_interact, mask_accepts,
    collider_name, entity_collider, set_collider, entity_pose, collider_pose
}

pub use lib::gjk {
    SV, Pair2, pair2, Gjk, gjk, gjk_is_overlap, gjk_distance, gjk_normal, gjk_pa, gjk_pb,
    Epa, epa, epa_depth, epa_normal, epa_pa, epa_pb
}

pub use lib::narrow {
    Proximity, proximity_new, prox_distance, prox_normal, prox_pa, prox_pb, prox_flip,
    Contact, contact_normal, contact_depth, contact_point_a, contact_point_b,
    seg_seg, proximity, proximity_gjk, collide, overlaps
}

pub use lib::world {
    Entry, entry_new, entry_entity, entry_collider, entry_pose, entry_bounds, entry_shape,
    entry_is_trigger, entry_is_plane, same_entity,
    Scene, scene_entries, scene_size, collision_scene, scene_of,
    Candidate, candidate_a, candidate_b, sort_by_min_x, broad_phase, brute_pairs
}

pub use lib::query {
    Hit, hit_entity, hit_t, hit_point, hit_normal, raycast, overlap,
    Push, push_entity, push_normal, push_depth, penetrations, shape_cast
}

pub use lib::controller {
    MoveConfig, move_config_default, move_config,
    Slide, slide_position, slide_grounded, slide_ground_normal, slide_ground, slide_hit_wall,
    slide_wall, slide_hit_ceiling, move_and_slide
}

pub use lib::events {
    PairKey, pair_key, pair_a, pair_b, key_eq, key_in, pair_other,
    Contacts, contacts_empty, contacts_current, contacts_started, contacts_ended,
    touching_pairs, contacts_next, partners,
    contacts_name, world_contacts, world_set_contacts, contacts_update, collision_system,
    started_with, ended_with, touching_with
}
