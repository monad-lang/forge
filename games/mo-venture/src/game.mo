// Mo Venture: the App. Update-stage systems, in order:
//
//   mo.intent  keys (or the autopilot) -> Intent
//   forge.orbit  camera rotation and zoom from input
//   mo.move    Mo's controller
//   mo.rules   sparks, checkpoints, falls, goal, HUD
//   mo.spin    sparks and the goal gem turn
//   mo.camera  the orbit follows Mo and publishes the camera

use init::id {Id}
use forge_core::ecs {World, Entity, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math {Vec3, vec3, v3_add, Quat, quat_mul, quat_from_axis_angle}
use forge_scene {Transform, transform_new, transform_name, entity_transform}
use forge_schedule {update_s, world_time, time_elapsed}
use forge_render {color}
use forge_collide {collision_scene}
use forge_app {
    App, app_new, app_add_system, app_set_assets, app_set_initial_world, app_set_clear_color,
    CameraRig, Orbit, orbit_new, orbit_rig, orbit_with_limits, world_orbit_opt, app_add_orbit_camera,
    world_orbit_follow, world_input, app_initial_world
}
use lib::level {Level, skyway}
use lib::look {Loaded, load, level_world, Spin, spin_name}
use lib::mo {world_set_intent, find_mo, mo_position, entity_mo, mo_move}
use lib::rules {rules_system}
use lib::bot {Bot, Thought, world_bot, world_set_bot, bot_think, bot_toggle, bot_on, bot_resync}
use lib::rules {GameState, world_game_opt, game_falls}
use lib::controls {keys_intent, autopilot_pressed}

// ── Camera ──────────────────────────────────────────────────────────

/// Behind Mo (+z of the start), a little above, looking down the course.
def camera_at (lv : Level) : Orbit :=
    orbit_with_limits (orbit_new (v3_add lv.start (vec3 0.0 1.2 0.0)) 0.0 0.38 8.0 0.9) 3.0 18.0

pub def mo_rig (lv : Level) : CameraRig := orbit_rig (camera_at lv)

def view_orbit (lv : Level) (world : World) : Orbit :=
    match world_orbit_opt world {
        Option.some o => o,
        Option.none => camera_at lv
    }

def follow (lv : Level) (world : World) : World :=
    match find_mo world {
        Option.some e => world_orbit_follow (camera_at lv) (v3_add (mo_position world e) (vec3 0.0 0.5 0.0)) 6.0 world,
        Option.none => world
    }

// ── Intent ──────────────────────────────────────────────────────────

def with_bot (lv : Level) (world : World) (b : Bot) : World :=
    if b.on
    then
        match find_mo world {
            Option.some e0 =>
                let e : Entity := e0 in
                let falls : I64 := match world_game_opt world {
                    Option.some g0 => let g : GameState := g0 in game_falls g,
                    Option.none => 0
                } in
                let b1 : Bot := bot_resync lv b (mo_position world e) falls in
                let t : Thought := bot_think lv (collision_scene world) b1 (entity_mo world e) (mo_position world e) in
                world_set_bot (world_set_intent world t.intent) t.bot,
            Option.none => world
        }
    else world_set_bot (world_set_intent world (keys_intent (world_input world) (view_orbit lv world))) b

/// Keys, unless the autopilot is on (P toggles it).
pub def intent_step (lv : Level) (world : World) : World :=
    let b0 : Bot := world_bot world in
    let b : Bot := if autopilot_pressed (world_input world) then bot_toggle b0 else b0 in
    with_bot lv world b

// ── Spin ────────────────────────────────────────────────────────────

def as_spin (v : Any) : Spin :=
    match v { Any.any x => let s : Spin := x in s }

def spin_one (world : World) (t : F64) (e : Entity) : World :=
    match get_component_named world e spin_name {
        Option.some v =>
            let s : Spin := as_spin v in
            match entity_transform world e {
                Option.some t0 =>
                    let tr : Transform := t0 in
                    let q : Quat := quat_mul (quat_from_axis_angle (vec3 0.0 1.0 0.0) (t * s.speed)) s.tilt in
                    insert_component world e transform_name (Any.any (transform_new tr.translation q tr.scale)),
                Option.none => world
            },
        Option.none => world
    }

#[terminating]
def spin_go (world : World) (t : F64) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest => spin_go (spin_one world t e) t rest
    }

pub def spin_step (world : World) : World :=
    spin_go world (time_elapsed (world_time world)) (query_entities world [spin_name, transform_name] [])

// ── The app ─────────────────────────────────────────────────────────

/// Mo Venture on level `lv`.
pub def mo_venture_on (lv : Level) : App :=
    let l : Loaded := load in
    let a0 : App := app_add_system app_new "mo.intent" update_s (WorldM.modify (intent_step lv)) in
    let a1 : App := app_add_orbit_camera a0 (camera_at lv) in
    let a2 : App := app_add_system a1 "mo.move" update_s (WorldM.modify mo_move) in
    let a3 : App := app_add_system a2 "mo.rules" update_s (rules_system lv) in
    let a4 : App := app_add_system a3 "mo.spin" update_s (WorldM.modify spin_step) in
    let a5 : App := app_add_system a4 "mo.camera" update_s (WorldM.modify (follow lv)) in
    app_set_clear_color (app_set_initial_world (app_set_assets a5 l.assets) (level_world l.looks lv))
        (color 0.56 0.78 0.96 1.0)

/// The game: the Skyway.
pub def mo_venture : App := mo_venture_on skyway

/// The same app with the autopilot switched on from the first frame.
pub def mo_venture_autopilot (lv : Level) : App :=
    let a : App := mo_venture_on lv in
    app_set_initial_world a (world_set_bot (app_initial_world a) bot_on)
