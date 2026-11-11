// forge-app: the `App` builder and its IO main loop. Phase 7, see
// ../../../PLAN.md.
//
// `App` is a PURE data structure (a schedule, a plugin list, a renderer, a
// starting world, a camera) until `app_run` is called; `app_run` is the only
// thing that touches IO. That split is what makes the loop testable: a test
// builds an app, runs N frames over a soft renderer, and inspects both the
// resulting world and the recorded commands.
//
// One frame (`app_step`):
//   1. `propagate_transforms` -- the scene graph, top-down.
//   2. `run_schedule_pure` -- every stage's systems, `World -> World`.
//   3. `extract` -- the world becomes `List RenderCommand`.
//   4. `renderer_submit` + `renderer_present` -- the only IO.
//
// Deviation from the plan: `app_run` RETURNS the final `World` rather than
// `IO Unit`. A caller that does not want it ignores it, and everything stays
// observable in a test. The fixed-timestep accumulator is forge-schedule's
// `Time`; wiring it in is deferred with real frame timing (this mote has no
// clock source yet).

use std::derive {derive_debug}
use std::list {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {
    World, Spawned, spawn, empty_world, world_entity_count
}
use forge_core::world_m {WorldM}
use forge_schedule {
    Schedule, ScheduleState, empty_schedule, add_system, run_schedule_pure,
    system_new, update_s
}
use forge_render {
    Renderer, headless_renderer, soft_renderer, renderer_recorded,
    renderer_is_recording, camera_new, Camera, Color, color_clear,
    RenderCommand, extract, renderer_submit, renderer_present
}
use forge_math {vec3, mat4_identity}
use forge_scene {propagate_transforms}
use lib::plugin {Plugin, plugin_named, plugin_name, plugin_setup}

/// A default camera at the origin looking down -z.
pub def default_camera : Camera :=
    camera_new mat4_identity mat4_identity (vec3 0.0 0.0 0.0)

/// The whole application description. `Copy` (hand-written identity): the
/// schedule and plugin list are immutable, the renderer is a shared backend
/// handle, and the world is a persistent structure -- duplicating the app
/// shares, never mutates.
#[derive Debug]
pub struct App {
    schedule : Schedule,
    plugins : List Plugin,
    renderer : Renderer,
    initial : World,
    camera : Camera,
    clear : Color,
    frames : I64
}

pub instance Copy App {
    def copy (a : App) : Pair App App := Pair.pair a a
}

/// An app with no systems, no plugins, a headless renderer and an empty world.
pub def app_new : App :=
    { schedule := empty_schedule,
      plugins := [],
      renderer := headless_renderer,
      initial := empty_world,
      camera := default_camera,
      clear := color_clear,
      frames := 0
      : App }

pub def app_schedule (a : App) : Schedule := a.schedule

pub def app_renderer (a : App) : Renderer := a.renderer

pub def app_camera (a : App) : Camera := a.camera

pub def app_clear_color (a : App) : Color := a.clear

pub def app_frame_budget (a : App) : I64 := a.frames

pub def app_initial_world (a : App) : World := a.initial

pub def app_plugin_names (a : App) : List String :=
    List.map (fn (p : Plugin) => plugin_name p) a.plugins

// ── Building ────────────────────────────────────────────────────────

pub def app_set_renderer (a : App) (r : Renderer) : App := { a with renderer := r }

pub def app_set_camera (a : App) (c : Camera) : App := { a with camera := c }

pub def app_set_clear_color (a : App) (c : Color) : App := { a with clear := c }

pub def app_set_initial_world (a : App) (w : World) : App := { a with initial := w }

/// How many frames `app_run` should run.
pub def app_set_frames (a : App) (n : I64) : App := { a with frames := n }

pub def app_add_plugin (a : App) (p : Plugin) : App :=
    { a with plugins := List.append a.plugins [p] }

/// Register a system (it runs in its own declared stage).
pub def app_add_system (a : App) (name : String) (stage : ScheduleState)
    (run : WorldM Id Unit) : App :=
    { a with schedule := add_system a.schedule (system_new name stage [] [] run) }

// ── The loop ────────────────────────────────────────────────────────

/// Run one frame: propagate, run the schedule, extract, submit + present.
pub def app_step (a : App) (world : World) : IO World := do {
    let world1 : World := run_schedule_pure (propagate_transforms world) a.schedule;
    let cmds : List RenderCommand := extract world1 a.camera a.clear;
    renderer_submit a.renderer cmds;
    renderer_present a.renderer;
    return world1
}

#[terminating]
def app_run_go (a : App) (world : World) (n : I64) : IO World :=
    if I64.lt 0 n
    then do {
        let next <- app_step a world;
        app_run_go a next (I64.sub n 1)
    }
    else Monad.pure world

#[terminating]
def run_plugins_go (ps : List Plugin) : IO Unit :=
    match ps {
        List.empty => Monad.pure unit,
        List.cons p rest => do {
            plugin_setup p;
            run_plugins_go rest
        }
    }

/// Run the plugins' setup, then `frames` frames from the initial world.
pub def app_run (a : App) : IO World := do {
    run_plugins_go a.plugins;
    app_run_go a a.initial a.frames
}

// ── The minimal demo ────────────────────────────────────────────────

/// A system body that spawns one entity.
pub def spawn_one : WorldM Id Unit :=
    WorldM.modify spawn_pos

def spawn_pos (w : World) : World :=
    let s : Spawned := spawn w [Pair.pair "pos" (Any.any 1u64)] in
    s.world

/// The minimal demo: one system, one frame budget, a recording renderer.
pub def demo_app (frames : I64) : IO App := do {
    let r <- soft_renderer 800 600;
    return (app_set_frames (app_set_renderer (app_add_system app_new "spawn" update_s spawn_one) r)
                           frames)
}

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_app_new_has_no_plugins : Bool :=
    List.is_empty (app_plugin_names app_new)

#[test]
def test_app_add_plugin_records_the_name : Bool :=
    let a : App := app_add_plugin app_new (plugin_named "core") in
    match List.first (app_plugin_names a) {
        Option.some n => String.beq n "core",
        Option.none => false
    }

#[test]
def test_app_set_renderer : IO Bool := do {
    let r <- soft_renderer 10 10;
    let a : App := app_set_renderer app_new r;
    return (renderer_is_recording (app_renderer a))
}

#[test]
def test_app_run_no_frames_returns_the_initial_world : IO Bool := do {
    let a : App := app_set_frames app_new 0;
    let w <- app_run a;
    return (I64.beq (world_entity_count w) 0)
}

#[test]
def test_app_step_records_a_frame : IO Bool := do {
    let r <- soft_renderer 10 10;
    let a : App := app_set_renderer app_new r;
    let _ <- app_step a empty_world;
    let recorded <- renderer_recorded r;
    // clear, set_camera, present
    return (I64.beq (List.length recorded) 3)
}

#[test]
def test_app_run_two_frames_records_two_frames : IO Bool := do {
    let r <- soft_renderer 10 10;
    let a : App := app_set_renderer (app_set_frames app_new 2) r;
    let _ <- app_run a;
    let recorded <- renderer_recorded r;
    // 2 frames x (clear, camera, present) = 6
    return (I64.beq (List.length recorded) 6)
}

#[test]
def test_app_add_system_runs_it : IO Bool := do {
    let r <- soft_renderer 10 10;
    let a : App :=
        app_set_frames
            (app_set_renderer
                (app_add_system app_new "spawn" update_s spawn_one) r)
            1;
    let w <- app_run a;
    return (I64.beq (world_entity_count w) 1)
}

#[test]
def test_demo_app_helper_builds : IO Bool := do {
    let a <- demo_app 3;
    let w <- app_run a;
    let r : Renderer := app_renderer a;
    let recorded <- renderer_recorded r;
    // The demo system spawns an entity with NO mesh, so a frame is still
    // clear + camera + present = 3; 3 frames = 9.
    return (I64.beq (world_entity_count w) 3 && I64.beq (List.length recorded) 9)
}
