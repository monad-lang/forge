// Mo Venture: forge's example game, a 3D platformer starring Mo. This is
// the game logic, native and tested; the web bin is `main.mo`.
//
// Run it: `devenv shell -- scripts/web-serve.sh mo-venture`.

pub use lib::tune {Tune, tune, mo_radius, mo_half_height, mo_stand}

pub use lib::level {
    Plat, plat, mover, plat_top, plat_moves, plat_to, plat_at_end, mover_dwell, mover_travel,
    Way, way, way_at, way_act, act_walk, act_jump, act_dash, act_double, act_double_dash, act_wait, act_ride,
    kind_grass, kind_stone, kind_wood, kind_gold,
    Level, level_new, level_name, level_plats, level_sparks, level_posts, level_goal, level_start, level_kill_y,
    level_route, level_spark_count, skyway, tiny_level
}

pub use lib::levels {cloud_steps, drift_docks, sun_spire, all_levels}

pub use lib::mo {
    Intent, intent, intent_none, intent_move, intent_name, world_intent, world_set_intent,
    MoState, long_ago, mo_rest, mo_airborne, mo_vel, mo_grounded, mo_dashed, mo_facing, mo_air_used, mo_with_vel, mo_with_air_used,
    mo_velocity, mo_landed, mo_shape, MoStep, step_state, step_pos, mo_step, yaw_quat,
    mo_name, entity_mo, set_mo, find_mo, mo_position, place_mo, mo_move, mo_system,
    Carrier, carrier_name, carrier_at, carrier_delta, carriers_step, body_name
}

pub use lib::look {
    Looks, Loaded, loaded_assets, loaded_looks, load, Spark, spark_name, Post, post_name,
    Goal, goal_name, Spin, spin_name, spawn_mo, level_world, spawn_level, clear_level, sun_name,
    hero_xiaozhu, hero_xiaomao, hero_count, hero_next, hero_name, dress_mo, redress_mo, spawn_mo_as, spawn_level_as
}

pub use lib::rules {
    msg_none, msg_checkpoint, msg_goal, GameState, game_new, game_sparks, game_total, game_falls,
    game_time, game_won, game_checkpoint, game_respawn, game_message_age, game_name, world_game_opt,
    world_set_game, world_clear_game,
    trunc_i64, fmt1, fmt2, rules_step, rules_system
}

pub use lib::bot {
    Bot, bot_off, bot_on, bot_is_on, bot_index, bot_toggle, arrive, Thought, thought_intent,
    thought_bot, bot_think, bot_resync, bot_restart, bot_done, bot_name, world_bot, world_set_bot
}

pub use lib::controls {keys_intent, autopilot_pressed}

pub use lib::game {
    Campaign, campaign_name, world_campaign_opt, campaign_index, campaign_count, campaign_hero, world_hero, world_level,
    world_level_index, campaign_step, banner_step, mo_rig, mo_sun, intent_step, animate_level, spin_step,
    mo_venture_levels, mo_venture_on, mo_venture, mo_venture_levels_autopilot, mo_venture_autopilot
}
