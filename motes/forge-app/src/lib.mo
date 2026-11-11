// forge-app: the App builder, Plugin, and the IO main loop. Phase 7, see
// ../../../PLAN.md.
//
// `App` is a pure data structure (schedule + plugins + renderer + world +
// camera) until `app_run`; `app_run` is the only IO. A test builds an app, runs
// N frames over a recording ("soft") renderer, and inspects both the resulting
// world and the recorded command list.

pub use lib::plugin {
    Plugin, plugin_new, plugin_named, plugin_name, plugin_setup
}

pub use lib::app {
    App, app_new, default_camera,
    app_schedule, app_renderer, app_camera, app_clear_color, app_frame_budget,
    app_initial_world, app_plugin_names,
    app_set_renderer, app_set_camera, app_set_clear_color, app_set_initial_world,
    app_set_frames, app_add_plugin, app_add_system,
    app_step, app_run, demo_app, spawn_one
}
