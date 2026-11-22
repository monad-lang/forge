// forge-app: the App builder, Plugin, and the IO main loop. Phase 7, see
// ../../../PLAN.md.
//
// `App` is a pure data structure (schedule + plugins + renderer + world +
// camera) until `app_run`; `app_run` is the only IO. A test builds an app, runs
// N frames over a recording ("soft") renderer, and inspects both the resulting
// world and the recorded command list.
//
// The browser host is the `forge_app::web` module (web-only, so it is NOT
// re-exported here: the native test binary would otherwise link WebGL
// externs). A web game names `forge_app` (this surface) and `forge_app::web`
// and nothing else.

pub use lib::plugin {
    Plugin, plugin_new, plugin_named, plugin_name, plugin_setup
}

pub use lib::app {
    App, app_new, default_camera,
    CameraRig, camera_rig, rig_camera,
    app_schedule, app_renderer, app_camera, app_clear_color, app_frame_budget,
    app_initial_world, app_plugin_names,
    app_set_renderer, app_set_camera, app_set_clear_color, app_set_initial_world, app_set_light,
    app_set_frames, app_add_plugin, app_add_system,
    app_assets, app_fixed_delta, app_set_assets, app_set_fixed_delta,
    Frame, frame_world, frame_commands, app_frame, app_frame_dt, app_frame_input, app_frame_viewed, app_plan,
    app_step, app_run, demo_app, spawn_one
}

pub use lib::input {
    Input, InputEvent, input_empty, input_apply, input_apply_all, input_end_frame,
    input_key_down, input_key_up, input_pointer_move, input_pointer_down, input_pointer_up,
    input_pointer_leave, input_wheel, input_focus_lost, input_wheel_pixels, input_is_scroll_key,
    button_primary, button_middle, button_secondary,
    input_key_held, input_key_pressed, input_key_released,
    input_button_held, input_button_pressed, input_button_released,
    input_pointer_x, input_pointer_y, input_delta_x, input_delta_y, input_wheel_delta,
    input_pointer_inside, input_held_keys, input_axis,
    input_name, world_input, world_input_opt, world_set_input
}

pub use lib::orbit {
    Orbit, orbit_new, orbit_with_limits, orbit_target, orbit_yaw, orbit_pitch, orbit_distance,
    orbit_eye, orbit_forward, orbit_right, orbit_rig, orbit_update,
    orbit_drag_speed, orbit_key_speed, orbit_zoom_speed, orbit_max_pitch,
    orbit_name, camera_rig_name, world_orbit_opt, world_set_orbit,
    world_camera_rig_opt, world_camera_rig, world_set_camera_rig,
    orbit_step, orbit_system, app_add_orbit_camera
}

pub use lib::hud {
    Hud, HudEntry, hud_entry, hud_entry_key, hud_entry_value, hud_empty, hud_list, hud_put,
    hud_lookup, hud_changes, hud_name, world_hud, world_set_hud, hud_set, hud_get
}

pub use lib::pick {pick_reach, world_pick}

pub use lib::orbit {orbit_set_target, orbit_set_angles, follow_alpha, orbit_follow, world_orbit_follow}
