// forge-app: the `App` builder and its IO main loop. Phase 7, see
// ../../../PLAN.md.
//
// `App` is a PURE data structure (a schedule, a plugin list, a renderer, a
// starting world, a camera) until `app_run` is called; `app_run` is the only
// thing that touches IO. That split is what makes the loop testable: a test
// builds an app, runs N frames over a soft renderer, and inspects both the
// resulting world and the recorded commands.
//
// One frame is PURE (`app_frame`, Phase 9a):
//   1. `propagate_transforms` -- so systems see current globals.
//   2. the schedule -- every stage's systems, `World -> World`.
//   3. `propagate_transforms` again -- so what a system moved or spawned THIS
//      frame is drawn this frame, not the next.
//   4. `extract` -- the world becomes `List RenderCommand`.
// and a HOST turns the result into pixels. `app_step` is the host for a
// `Renderer` (`renderer_submit` + `renderer_present`, the only IO here); the
// browser host is forge-webgl, reached through `forge_app::web`. Neither
// changes what a frame is.
//
// `app_frame_dt` is the same frame under a real clock: it advances the
// world's `Time` resource by `dt` and repeats the fixed stage as the
// accumulator dictates. `app_frame` (no clock) is what `app_run`'s fixed
// frame count uses.
//
// Deviation from the plan: `app_run` RETURNS the final `World` rather than
// `IO Unit`. A caller that does not want it ignores it, and everything stays
// observable in a test.

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
    system_new, update_s, fixed_update_s, run_frame, default_fixed_delta,
    Time, world_time, time_elapsed, time_fixed_steps
}
use forge_render {
    Renderer, headless_renderer, soft_renderer, renderer_recorded,
    renderer_is_recording, camera_new, Camera, Color, color_clear,
    RenderCommand, extract, renderer_submit, renderer_present, camera_projection,
    camera_position,
    Assets, assets_empty, FramePlan, frame_plan, plan_draw_count, count_draws
}
use forge_math {
    Mat4, Vec3, vec3, mat4_identity, mat4_look_at, mat4_perspective, f64_abs
}
use forge_scene {propagate_transforms}
use lib::plugin {Plugin, plugin_named, plugin_name, plugin_setup}

/// A default camera at the origin looking down -z.
pub def default_camera : Camera :=
    camera_new mat4_identity mat4_identity (vec3 0.0 0.0 0.0)

// ── Camera rig ──────────────────────────────────────────────────────

/// A perspective camera described by where it is, not by its matrices, so a
/// host can rebuild the projection whenever the surface's aspect changes.
/// `fovy` is the vertical field of view in radians.
#[derive Copy Clone Debug]
pub struct CameraRig {
    eye : Vec3,
    target : Vec3,
    up : Vec3,
    fovy : F64,
    near : F64,
    far : F64
}

pub def camera_rig (eye : Vec3) (target : Vec3) (fovy : F64) : CameraRig :=
    { eye := eye, target := target, up := vec3 0.0 1.0 0.0, fovy := fovy, near := 0.1, far := 100.0
      : CameraRig }

/// The rig's camera for a `width` x `height` surface (any unit).
pub def rig_camera (r : CameraRig) (width : F64) (height : F64) : Camera :=
    let aspect : F64 := if height > 0.0 then width / height else 1.0 in
    camera_new (mat4_look_at r.eye r.target r.up)
               (mat4_perspective r.fovy aspect r.near r.far)
               r.eye

/// The whole application description. `Copy` (hand-written identity): the
/// schedule and plugin list are immutable, the renderer is a shared backend
/// handle, and the world is a persistent structure -- duplicating the app
/// shares, never mutates.
pub struct App {
    schedule : Schedule,
    plugins : List Plugin,
    renderer : Renderer,
    initial : World,
    camera : Camera,
    clear : Color,
    frames : I64,
    assets : Assets,
    fixed_delta : F64
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
      frames := 0,
      assets := assets_empty,
      fixed_delta := default_fixed_delta
      : App }

pub def app_schedule (a : App) : Schedule := a.schedule

pub def app_renderer (a : App) : Renderer := a.renderer

pub def app_camera (a : App) : Camera := a.camera

pub def app_clear_color (a : App) : Color := a.clear

pub def app_frame_budget (a : App) : I64 := a.frames

pub def app_initial_world (a : App) : World := a.initial

/// The mesh/material/texture tables a drawing backend uploads from.
pub def app_assets (a : App) : Assets := a.assets

/// The fixed-update step, in seconds.
pub def app_fixed_delta (a : App) : F64 := a.fixed_delta

pub def app_plugin_names (a : App) : List String :=
    List.map (fn (p : Plugin) => plugin_name p) a.plugins

// ── Building ────────────────────────────────────────────────────────

pub def app_set_renderer (a : App) (r : Renderer) : App := { a with renderer := r }

pub def app_set_camera (a : App) (c : Camera) : App := { a with camera := c }

pub def app_set_clear_color (a : App) (c : Color) : App := { a with clear := c }

pub def app_set_initial_world (a : App) (w : World) : App := { a with initial := w }

pub def app_set_assets (a : App) (assets : Assets) : App := { a with assets := assets }

/// The fixed-update step in seconds (default 1/60).
pub def app_set_fixed_delta (a : App) (dt : F64) : App := { a with fixed_delta := dt }

/// How many frames `app_run` should run.
pub def app_set_frames (a : App) (n : I64) : App := { a with frames := n }

pub def app_add_plugin (a : App) (p : Plugin) : App :=
    { a with plugins := List.append a.plugins [p] }

/// Register a system (it runs in its own declared stage).
pub def app_add_system (a : App) (name : String) (stage : ScheduleState)
    (run : WorldM Id Unit) : App :=
    { a with schedule := add_system a.schedule (system_new name stage [] [] run) }

// ── The loop ────────────────────────────────────────────────────────

/// What one frame produces: the next world and the commands that draw it.
/// A named `Copy` struct rather than a `Pair`, whose two halves could not
/// both be read under the affine rule. (`Copy` is the identity form: a world
/// and an immutable list.)
pub struct Frame {
    world : World,
    commands : List RenderCommand
}

pub instance Copy Frame {
    def copy (f : Frame) : Pair Frame Frame := Pair.pair f f
}

pub def frame_world (f : Frame) : World := f.world

pub def frame_commands (f : Frame) : List RenderCommand := f.commands

def frame_of (a : App) (after_systems : World) : Frame :=
    let world : World := propagate_transforms after_systems in
    { world := world, commands := extract world a.camera a.clear : Frame }

/// One frame, PURELY: propagate, run the schedule, propagate, extract. No
/// clock: the fixed stage runs exactly once, like every other stage.
pub def app_frame (a : App) (world : World) : Frame :=
    frame_of a (run_schedule_pure (propagate_transforms world) a.schedule)

/// One frame under a real clock: the world's `Time` advances by `dt` seconds
/// and the fixed stage runs once per accumulated `app_fixed_delta`. Systems
/// read the clock with `world_time`.
pub def app_frame_dt (a : App) (world : World) (dt : F64) : Frame :=
    frame_of a (run_frame (propagate_transforms world) a.schedule a.fixed_delta dt)

/// Resolve a frame against the app's assets: what a drawing backend executes.
pub def app_plan (a : App) (f : Frame) : FramePlan := frame_plan a.assets f.commands

/// Run one frame and hand it to the app's `Renderer`: `app_frame`, then
/// submit + present.
pub def app_step (a : App) (world : World) : IO World := do {
    let f : Frame := app_frame a world;
    renderer_submit a.renderer f.commands;
    renderer_present a.renderer;
    return f.world
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

#[test]
def test_app_frame_is_pure_and_matches_app_step : IO Bool := do {
    // `app_step` is `app_frame` + submit: the recording holds exactly the
    // frame's commands, and both arrive at the same world.
    let r <- soft_renderer 10 10;
    let a : App := app_set_renderer (app_add_system app_new "spawn" update_s spawn_one) r;
    let f : Frame := app_frame a empty_world;
    let w <- app_step a empty_world;
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) (List.length (frame_commands f))
            && I64.beq (world_entity_count w) (world_entity_count (frame_world f)))
}

#[test]
def test_app_frame_dt_advances_the_world_clock : Bool :=
    let f1 : Frame := app_frame_dt app_new empty_world 0.25 in
    let f2 : Frame := app_frame_dt app_new (frame_world f1) 0.25 in
    let t : Time := world_time (frame_world f2) in
    time_elapsed t > 0.4999 && time_elapsed t < 0.5001

#[test]
def test_app_frame_dt_repeats_the_fixed_stage : Bool :=
    // 0.1 s steps, one 0.35 s frame: three fixed steps. The fourth entity is
    // the clock's holder.
    let a : App :=
        app_set_fixed_delta (app_add_system app_new "fixed" fixed_update_s spawn_one) 0.1 in
    let f : Frame := app_frame_dt a empty_world 0.35 in
    I64.beq (world_entity_count (frame_world f)) 4
        && I64.beq (time_fixed_steps (world_time (frame_world f))) 3

#[test]
def test_app_frame_dt_below_a_step_runs_no_fixed_system : Bool :=
    let a : App :=
        app_set_fixed_delta (app_add_system app_new "fixed" fixed_update_s spawn_one) 0.1 in
    let f : Frame := app_frame_dt a empty_world 0.01 in
    I64.beq (world_entity_count (frame_world f)) 1

#[test]
def test_app_plan_of_an_empty_app_draws_nothing : Bool :=
    let f : Frame := app_frame app_new empty_world in
    I64.beq (plan_draw_count (app_plan app_new f)) 0 && I64.beq (count_draws (frame_commands f)) 0

#[test]
def test_rig_camera_position_and_aspect : Bool :=
    let rig : CameraRig := camera_rig (vec3 0.0 0.0 5.0) (vec3 0.0 0.0 0.0) 1.0 in
    let wide : Camera := rig_camera rig 800.0 400.0 in
    let square : Camera := rig_camera rig 400.0 400.0 in
    // x scale is f / aspect: half as large at aspect 2 as at aspect 1.
    let pw : Mat4 := camera_projection wide in
    let ps : Mat4 := camera_projection square in
    let pos : Vec3 := camera_position wide in
    f64_abs (pw.cx.x * 2.0 - ps.cx.x) < 0.000001 && F64.beq pos.z 5.0

#[test]
def test_rig_camera_survives_a_zero_height : Bool :=
    let rig : CameraRig := camera_rig (vec3 0.0 0.0 5.0) (vec3 0.0 0.0 0.0) 1.0 in
    let c : Camera := rig_camera rig 800.0 0.0 in
    let p : Mat4 := camera_projection c in
    p.cx.x > 0.0
