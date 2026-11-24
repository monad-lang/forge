// Mo Venture: the App. Update-stage systems, in order:
//
//   mo.campaign  level keys (1-4, Backspace), Enter after the goal -> next level,
//                C switches Mo between Xiaozhu (piggy) and Xiaomao (kitty)
//   mo.intent    keys (or the autopilot) -> Intent
//   forge.orbit  camera rotation and zoom from input
//   mo.animate   moving platforms, flags and the gem (forge-animate); carrier deltas
//   mo.move      Mo's controller (carried by moving platforms)
//   mo.rules     sparks, checkpoints, falls, goal, HUD
//   mo.banner    the goal message and the level on the HUD
//   mo.tween     spark pops, squash and stretch
//   mo.spin      sparks and the goal gem turn
//   mo.camera    the orbit follows Mo; the sun's shadow box and disc follow too
//
// The levels are a `Campaign` resource: the list, where the player is, and
// the asset handles to spawn the next one with, and which hero Mo is.
// Every system reads the current level from it.

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math {Vec3, vec3, v3_add, v3_scale, Quat, quat_mul, quat_from_axis_angle, f64_wrap_angle}
use forge_scene {Transform, transform_new, transform_name, entity_transform}
use forge_schedule {update_s, world_time, time_elapsed}
use forge_render {color, Light, light_sun, light_with_shadows, light_at, light_toward, world_light, world_set_light}
use forge_collide {collision_scene, Scene}
use forge_animate {animate_step, tween_step}
use forge_app {
    App, app_new, app_add_system, app_set_assets, app_set_initial_world, app_set_clear_color, app_set_light,
    CameraRig, Orbit, orbit_new, orbit_rig, orbit_with_limits, world_orbit_opt, app_add_orbit_camera,
    world_orbit_follow, world_input, app_initial_world, Input, input_key_pressed, hud_set,
    orbit_forward, orbit_right
}
use lib::level {Level, skyway, level_name, level_start, level_kill_y}
use lib::levels {all_levels}
use lib::hero {hero_xiaozhu, hero_next, hero_name}
use lib::look {
    Looks, Loaded, load, level_world, spawn_level_as, clear_level, Spin, spin_name, sun_name
}
use lib::mo {
    world_set_intent, world_intent, find_mo, find_companion, mo_position, entity_mo, mo_move, carriers_step,
    mo_swap, mo_hero, mo_facing, world_set_follow_intent, intent_swapped, Intent, MoState
}
use lib::rules {
    rules_step, GameState, world_game_opt, game_falls, game_won, game_message_age, world_clear_game
}
use lib::bot {Bot, Thought, world_bot, world_set_bot, bot_think, bot_toggle, bot_on, bot_is_on, bot_resync, bot_restart}
use lib::controls {keys_intent, autopilot_pressed}
use lib::companion {
    Follow, follow_seed, follow_step, follow_intent, world_follow_opt, world_set_follow, leash_step
}
use lib::tune {tune}

// ── Campaign ────────────────────────────────────────────────────────

/// The levels, the current one's index, the asset handles, and the hero
/// (`hero_xiaozhu` or `hero_xiaomao`). `Copy` (identity: a persistent list
/// and `Copy` handles).
pub struct Campaign {
    levels : List Level,
    index : I64,
    looks : Looks,
    hero : I64
}

pub instance Copy Campaign {
    def copy (c : Campaign) : Pair Campaign Campaign := Pair.pair c c
}

pub def campaign_name : String := "mo.campaign"

def as_campaign (v : Any) : Campaign :=
    match v { Any.any x => let c : Campaign := x in c }

pub def world_campaign_opt (world : World) : Option Campaign :=
    match List.first (query_entities world [campaign_name] []) {
        Option.some e =>
            match get_component_named world e campaign_name {
                Option.some v => Option.some (as_campaign v),
                Option.none => Option.none
            },
        Option.none => Option.none
    }

def world_set_campaign (world : World) (c : Campaign) : World :=
    match List.first (query_entities world [campaign_name] []) {
        Option.some e => insert_component world e campaign_name (Any.any c),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair campaign_name (Any.any c)] in
            s.world
    }

pub def campaign_index (c : Campaign) : I64 := c.index

pub def campaign_count (c : Campaign) : I64 := List.length c.levels

pub def campaign_hero (c : Campaign) : I64 := c.hero

/// The hero the player controls: Mo's own identity, else the campaign's
/// memory (Xiaozhu without either).
pub def world_hero (world : World) : I64 :=
    match find_mo world {
        Option.some e => mo_hero (entity_mo world e),
        Option.none =>
            match world_campaign_opt world {
                Option.some c => campaign_hero c,
                Option.none => hero_xiaozhu
            }
    }

def level_of (c : Campaign) (i : I64) : Level :=
    match List.get i c.levels {
        Option.some lv => lv,
        Option.none => skyway
    }

/// The level being played.
pub def world_level (world : World) : Level :=
    match world_campaign_opt world {
        Option.some c0 => let c : Campaign := c0 in level_of c c.index,
        Option.none => skyway
    }

/// The current level's index (0 without a campaign).
pub def world_level_index (world : World) : I64 :=
    match world_campaign_opt world {
        Option.some c => c.index,
        Option.none => 0
    }

/// Level `i` from the start: the old level's entities and run state go,
/// the new level is spawned, the autopilot restarts its route. Time, input,
/// the camera, the light and the HUD stay.
def goto (world : World) (c : Campaign) (i : I64) : World :=
    let w1 : World := spawn_level_as c.looks c.hero (world_clear_game (clear_level world)) (level_of c i) in
    let w2 : World := world_set_campaign w1 { levels := c.levels, index := i, looks := c.looks, hero := c.hero : Campaign } in
    world_set_bot w2 (bot_restart (world_bot w2))

/// Record `h` as the controlled hero (the HUD and level changes read it).
def set_campaign_hero (world : World) (h : I64) : World :=
    match world_campaign_opt world {
        Option.some c0 =>
            let c : Campaign := c0 in
            world_set_campaign world { levels := c.levels, index := c.index, looks := c.looks, hero := h : Campaign },
        Option.none => world
    }

/// The camera's ground-plane basis for the current view: forward and right.
/// The companion's slot is expressed in it (`companion.mo`), so the follower
/// stands where the camera sees, not where Mo happens to face.
pub def camera_basis (world : World) : Pair Vec3 Vec3 :=
    let o : Orbit := view_orbit world in
    Pair.pair (orbit_forward o) (orbit_right o)

/// `C` swaps which Mo the player controls; either way, the other one
/// follows. The companion's intent for this frame is computed here, from the
/// player's post-swap position and the camera's basis.
pub def control_step (world : World) : World :=
    let i : Intent := world_intent world in
    let w1 : World := if intent_swapped i then mo_swap world else world in
    let w2 : World :=
        match find_mo w1 {
            Option.some p => set_campaign_hero w1 (mo_hero (entity_mo w1 p)),
            Option.none => w1
        } in
    match find_mo w2 {
        Option.some p0 =>
            let p : Entity := p0 in
            match find_companion w2 {
                Option.none => w2,
                Option.some c0 => follow_for w2 p c0
            },
        Option.none => w2
    }

/// Compute the companion's slot and intent for this frame, and remember the
/// slot (the `mo.follow` resource is what makes the walk latch).
def follow_for (world : World) (p : Entity) (c : Entity) : World :=
    let basis : Pair Vec3 Vec3 := camera_basis world in
    match basis {
        Pair.pair cam_f0 cam_r0 =>
            let cam_f : Vec3 := cam_f0 in
            let cam_r : Vec3 := cam_r0 in
            let sc : Scene := collision_scene world in
            let pos : Vec3 := mo_position world c in
            let pp : Vec3 := mo_position world p in
            let s : MoState := entity_mo world c in
            let f0 : Follow := match world_follow_opt world {
                Option.some x => x,
                Option.none => follow_seed tune sc pos pp cam_f cam_r
            } in
            let f1 : Follow := follow_step tune sc f0 pos pp cam_f cam_r in
            let w1 : World := world_set_follow world f1 in
            world_set_follow_intent w1 (follow_intent tune sc s pos f1)
    }

/// Bring a stranded companion back to the player's side.
pub def companion_now (world : World) : World :=
    let basis : Pair Vec3 Vec3 := camera_basis world in
    match basis {
        Pair.pair cam_f cam_r =>
            leash_step tune (collision_scene world) (level_kill_y (world_level world)) cam_f cam_r world
    }

def key_level (world : World) : I64 :=
    let i : Input := world_input world in
    if input_key_pressed i "Digit1" then 0
    else if input_key_pressed i "Digit2" then 1
    else if input_key_pressed i "Digit3" then 2
    else if input_key_pressed i "Digit4" then 3
    else if input_key_pressed i "Digit5" then 4
    else if input_key_pressed i "Digit6" then 5
    else 0 - 1

def won_for (world : World) : F64 :=
    match world_game_opt world {
        Option.some g0 => let g : GameState := g0 in if game_won g then game_message_age g else 0.0 - 1.0,
        Option.none => 0.0 - 1.0
    }

def campaign_with (world : World) (c : Campaign) : World :=
    let k : I64 := key_level world in
    let age : F64 := won_for world in
    let next_ok : Bool := c.index + 1 < campaign_count c in
    let enter : Bool := input_key_pressed (world_input world) "Enter" in
    let bot : Bool := bot_is_on (world_bot world) in
    if k >= 0 && k < campaign_count c then goto world c k
    else if input_key_pressed (world_input world) "Backspace" then goto world c c.index
    else if age >= 0.0 && next_ok && (enter || (bot && age > 2.5)) then goto world c (c.index + 1)
    else world

/// Level keys (1-4), Backspace to restart, Enter (or the autopilot, after a pause)
/// to go on after the goal, C to switch hero.
pub def campaign_step (world : World) : World :=
    match world_campaign_opt world {
        Option.some c => campaign_with world c,
        Option.none => world
    }

/// The goal message, and which level this is.
pub def banner_step (world : World) : World :=
    match world_campaign_opt world {
        Option.some c0 =>
            let c : Campaign := c0 in
            let n : I64 := campaign_count c in
            let w1 : World := hud_set world "level" (String.concat (I64.to_string (c.index + 1)) (String.concat "/" (I64.to_string n))) in
            let w1h : World := hud_set w1 "hero" (hero_name (world_hero w1)) in
            let w2 : World := hud_set w1h "level-name" (level_name (level_of c c.index)) in
            if won_for w2 >= 0.0
            then hud_set w2 "message" (if c.index + 1 < n then "Goal! Enter: next level" else "Goal! Every level done")
            else w2,
        Option.none => world
    }

// ── Camera and sun ──────────────────────────────────────────────────

/// Behind Mo (+z of the start), a little above, looking down the course.
def camera_at (lv : Level) : Orbit :=
    orbit_with_limits (orbit_new (v3_add lv.start (vec3 0.0 1.2 0.0)) 0.0 0.38 8.0 0.9) 3.0 18.0

pub def mo_rig (lv : Level) : CameraRig := orbit_rig (camera_at lv)

pub def view_orbit (world : World) : Orbit :=
    match world_orbit_opt world {
        Option.some o => o,
        Option.none => camera_at (world_level world)
    }

/// The sun: warm, high and ahead of the course, shadows in a 44-unit box
/// around Mo.
pub def mo_sun : Light :=
    light_with_shadows (light_sun (vec3 (0.0 - 0.35) 0.95 (0.0 - 0.55)) (vec3 1.0 0.96 0.88) 0.62 0.42) 22.0 70.0 2048

/// The sun disc, far out along the light from `p` (inside the camera's far
/// plane).
def place_sun (world : World) (p : Vec3) : World :=
    match List.first (query_entities world [sun_name, transform_name] []) {
        Option.some e0 =>
            let e : Entity := e0 in
            let at : Vec3 := v3_add p (v3_scale (light_toward (world_light world)) 70.0) in
            match entity_transform world e {
                Option.some t0 =>
                    let t : Transform := t0 in
                    insert_component world e transform_name (Any.any (transform_new at t.rotation t.scale)),
                Option.none => world
            },
        Option.none => world
    }

def follow_at (world : World) (p : Vec3) : World :=
    let w1 : World := world_orbit_follow (camera_at (world_level world)) (v3_add p (vec3 0.0 0.5 0.0)) 6.0 world in
    place_sun (world_set_light w1 (light_at (world_light w1) p)) p

def follow (world : World) : World :=
    match find_mo world {
        Option.some e => follow_at world (mo_position world e),
        Option.none => world
    }

// ── Intent ──────────────────────────────────────────────────────────

def with_bot (world : World) (b : Bot) : World :=
    if b.on
    then
        match find_mo world {
            Option.some e0 =>
                let e : Entity := e0 in
                let lv : Level := world_level world in
                let falls : I64 := match world_game_opt world {
                    Option.some g0 => let g : GameState := g0 in game_falls g,
                    Option.none => 0
                } in
                let b1 : Bot := bot_resync lv b (mo_position world e) falls in
                let t : Thought := bot_think lv (collision_scene world) b1 (entity_mo world e) (mo_position world e) in
                world_set_bot (world_set_intent world t.intent) t.bot,
            Option.none => world
        }
    else world_set_bot (world_set_intent world (keys_intent (world_input world) (view_orbit world))) b

/// Keys, unless the autopilot is on (P toggles it).
pub def intent_step (world : World) : World :=
    let b0 : Bot := world_bot world in
    let b : Bot := if autopilot_pressed (world_input world) then bot_toggle b0 else b0 in
    with_bot world b

// ── Animation and rules ─────────────────────────────────────────────

/// The animators (movers, flags, the gem), then each mover's delta.
pub def animate_level (world : World) : World := carriers_step (animate_step world)

def rules_now (world : World) : World := rules_step (world_level world) world

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
                    // Wrapped: the clock grows without bound, the angle must not.
                    let q : Quat := quat_mul (quat_from_axis_angle (vec3 0.0 1.0 0.0) (f64_wrap_angle (t * s.speed))) s.tilt in
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

/// Mo Venture over `levels`, starting on the first.
pub def mo_venture_levels (levels : List Level) : App :=
    let l : Loaded := load in
    let sh : Shared (List Level) := Shared.of levels in
    let first : Level := match List.first (Shared.get sh) {
        Option.some lv => lv,
        Option.none => skyway
    } in
    let a0 : App := app_add_system app_new "mo.campaign" update_s (WorldM.modify campaign_step) in
    let a1 : App := app_add_system a0 "mo.intent" update_s (WorldM.modify intent_step) in
    let a1c : App := app_add_system a1 "mo.control" update_s (WorldM.modify control_step) in
    let a2 : App := app_add_orbit_camera a1c (camera_at first) in
    let a3 : App := app_add_system a2 "mo.animate" update_s (WorldM.modify animate_level) in
    let a4 : App := app_add_system a3 "mo.move" update_s (WorldM.modify mo_move) in
    let a5 : App := app_add_system a4 "mo.rules" update_s (WorldM.modify rules_now) in
    let a5c : App := app_add_system a5 "mo.companion" update_s (WorldM.modify companion_now) in
    let a6 : App := app_add_system a5c "mo.banner" update_s (WorldM.modify banner_step) in
    let a7 : App := app_add_system a6 "mo.tween" update_s (WorldM.modify tween_step) in
    let a8 : App := app_add_system a7 "mo.spin" update_s (WorldM.modify spin_step) in
    let a9 : App := app_add_system a8 "mo.camera" update_s (WorldM.modify follow) in
    let world : World := world_set_campaign (level_world l.looks first)
                             { levels := Shared.get sh, index := 0, looks := l.looks, hero := hero_xiaozhu : Campaign } in
    app_set_light
        (app_set_clear_color (app_set_initial_world (app_set_assets a9 l.assets) world) (color 0.5 0.74 0.95 1.0))
        mo_sun

/// Mo Venture on one level `lv`.
pub def mo_venture_on (lv : Level) : App := mo_venture_levels [lv]

/// The game: every level, from the Skyway.
pub def mo_venture : App := mo_venture_levels all_levels

/// `mo_venture_levels` with the autopilot switched on from the first frame.
pub def mo_venture_levels_autopilot (levels : List Level) : App :=
    let a : App := mo_venture_levels levels in
    app_set_initial_world a (world_set_bot (app_initial_world a) bot_on)

/// The same app on one level with the autopilot on.
pub def mo_venture_autopilot (lv : Level) : App := mo_venture_levels_autopilot [lv]
