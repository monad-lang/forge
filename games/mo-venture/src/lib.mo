// Mo Venture: forge's example game, a 3D platformer starring Mo. This is
// the game logic, native and tested; the web bin is `main.mo`.
//
// Run it: `devenv shell -- scripts/web-serve.sh mo-venture`.

pub use lib::tune {Tune, tune, mo_radius, mo_half_height, mo_stand}

pub use lib::hero {
    hero_xiaozhu, hero_xiaomao, hero_count, hero_next, hero_name, hero_ability, ability_name,
    ability_none, ability_spin, ability_slam
}

pub use lib::level {
    Plat, plat, mover, plat_top, plat_moves, plat_to, plat_at_end, mover_dwell, mover_travel,
    Way, way, way_at, way_act, act_walk, act_jump, act_dash, act_double, act_double_dash, act_wait, act_ride,
    kind_grass, kind_stone, kind_wood, kind_gold, kind_climb,
    act_ability, act_slam, act_spin, act_climb, act_as_kitty, act_as_piggy,
    Switch, switch_at, switch_pos, switch_gate, Gate, gate_box, gate_pos, gate_half, gate_id,
    Level, level_new, level_puzzles, level_name, level_plats, level_climbs, level_boxes, level_switches,
    level_gates, level_sparks, level_posts, level_goal, level_start, level_kill_y,
    level_route, level_spark_count, skyway, tiny_level
}

pub use lib::levels {cloud_steps, drift_docks, sun_spire, vine_wall, brick_yard, all_levels}

pub use lib::mo {
    Intent, intent, intent_ext, intent_ability, intent_swap, intent_none, intent_move,
    intent_ability_pressed, intent_swapped, intent_name, world_intent, world_set_intent,
    MoState, long_ago, mo_rest, mo_rest_for, mo_airborne, mo_airborne_for, mo_vel, mo_grounded, mo_dashed,
    mo_facing, mo_air_used, mo_with_vel, mo_with_air_used, mo_hero, mo_with_hero, mo_climbing,
    mo_with_climb, mo_ability, mo_ability_age, mo_with_ability,
    mo_velocity, mo_landed, mo_shape, MoStep, step_state, step_pos, mo_step, yaw_quat,
    mo_name, entity_mo, set_mo, find_mo, find_companion, has_marker, is_player, mo_swap,
    player_name, companion_name, follow_intent_name, world_follow_intent, world_set_follow_intent,
    clear_footing, mo_position, place_mo, mo_move, mo_system,
    layer_world, layer_climb, layer_mo, mo_move_mask, mo_move_config, mo_move_layers, climbing_wall,
    Carrier, carrier_name, carrier_at, carrier_delta, carriers_step, body_name
}

pub use lib::look {
    Looks, Loaded, loaded_assets, loaded_looks, load, Spark, spark_name, Post, post_name,
    Goal, goal_name, Spin, spin_name, spawn_mo, level_world, spawn_level, clear_level, sun_name,
    dress_mo, redress_mo, spawn_mo_as, spawn_level_as,
    box_name, switch_name, gate_name, box_half
}

pub use lib::rules {
    msg_none, msg_checkpoint, msg_goal, GameState, game_new, game_sparks, game_total, game_falls,
    game_time, game_won, game_checkpoint, game_respawn, game_message_age, game_name, world_game_opt,
    world_set_game, world_clear_game, game_kill_y,
    trunc_i64, fmt1, fmt2, rules_step, rules_system
}

pub use lib::bot {
    Bot, bot_off, bot_on, bot_is_on, bot_index, bot_toggle, arrive, Thought, thought_intent,
    thought_bot, bot_think, bot_resync, bot_restart, bot_done, bot_name, world_bot, world_set_bot,
    toward, ground_ahead, ground_at, wall_ahead
}

pub use lib::companion {
    Follow, follow_new, follow_name, follow_target_of, follow_moving, world_follow_opt, world_set_follow,
    follow_slot, follow_step, follow_seed, follow_intent, leash_step, ground_y_at, slot_probe_drop
}

pub use lib::controls {keys_intent, autopilot_pressed}

pub use lib::game {
    Campaign, campaign_name, world_campaign_opt, campaign_index, campaign_count, campaign_hero, world_hero, world_level,
    world_level_index, campaign_step, banner_step, mo_rig, mo_sun, intent_step, animate_level, spin_step,
    control_step, companion_now,
    mo_venture_levels, mo_venture_on, mo_venture, mo_venture_levels_autopilot, mo_venture_autopilot
}

// Co-op: a guest's intent for the companion, and the state a host ships to
// that guest. Native and tested; the socket glue is `forge_app::web`.
pub use lib::coop {
    world_set_guest_intent, world_clear_guest_intent, has_guest, intent_of_wire,
    hero_of, coop_state, coop_state_text, apply_state, apply_state_text,
    coop_input_intent, mo_coop_hooks
}
