// Mo Venture: forge's example game, a 3D platformer starring Mo. This is
// the game logic, native and tested; the web bin is `main.mo`.
//
// Run it: `devenv shell -- scripts/web-serve.sh mo-venture`.

pub use lib::tune {Tune, tune, mo_radius, mo_half_height, mo_stand}

pub use lib::level {
    Plat, plat, plat_top, Way, way_at, way_act, act_walk, act_jump, act_dash,
    kind_grass, kind_stone, kind_wood, kind_gold,
    Level, level_new, level_plats, level_sparks, level_posts, level_goal, level_start, level_kill_y,
    level_route, level_spark_count, skyway, tiny_level
}

pub use lib::mo {
    Intent, intent, intent_none, intent_move, intent_name, world_intent, world_set_intent,
    MoState, long_ago, mo_rest, mo_airborne, mo_vel, mo_grounded, mo_dashed, mo_facing, mo_with_vel,
    mo_velocity, mo_landed, mo_shape, MoStep, step_state, step_pos, mo_step, yaw_quat,
    mo_name, entity_mo, set_mo, find_mo, mo_position, place_mo, mo_move, mo_system
}

pub use lib::look {
    Looks, Loaded, loaded_assets, loaded_looks, load, Spark, spark_name, Post, post_name,
    Goal, goal_name, Spin, spin_name, spawn_mo, level_world
}

pub use lib::rules {
    msg_none, msg_checkpoint, msg_goal, GameState, game_new, game_sparks, game_total, game_falls,
    game_time, game_won, game_checkpoint, game_respawn, game_name, world_game_opt, world_set_game,
    trunc_i64, fmt1, fmt2, rules_step, rules_system
}

pub use lib::bot {
    Bot, bot_off, bot_on, bot_is_on, bot_index, bot_toggle, arrive, Thought, thought_intent,
    thought_bot, bot_think, bot_resync, bot_done, bot_name, world_bot, world_set_bot
}

pub use lib::controls {keys_intent, autopilot_pressed}

pub use lib::game {mo_rig, intent_step, spin_step, mo_venture_on, mo_venture, mo_venture_autopilot}
