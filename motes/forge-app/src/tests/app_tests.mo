// forge-app integration tests, over the PUBLIC surface (`lib::{...}`).
//
// The in-file tests drive the loop with a system that only spawns. These drive
// the WHOLE stack: forge-scene builds a hierarchy, forge-render extracts it,
// and the recording backend shows that a meshed entity actually produced a
// draw command.

use lib::{
    App, app_new, app_set_renderer, app_set_frames, app_set_initial_world,
    app_add_plugin, app_run, app_renderer, app_plugin_names,
    Plugin, plugin_named
}
use forge_render::{
    RenderCommand,
    Renderer, soft_renderer, renderer_recorded, count_draws, command_kind,
    MeshComponent, mesh_component, mesh_handle, material_handle, set_mesh
}
use forge_core::ecs {World, Spawned, empty_world, world_entity_count}
use forge_math::{vec3, Vec3}
use forge_scene::{spawn_transform, transform_from_translation}

/// A world with one transformed entity that also carries a mesh.
def meshed_world : World :=
    let s : Spawned :=
        spawn_transform empty_world (transform_from_translation (vec3 1.0 2.0 3.0)) in
    set_mesh s.world s.entity (mesh_component (mesh_handle 1) (material_handle 1))

#[test]
def test_a_meshed_entity_is_drawn : IO Bool := do {
    let r <- soft_renderer 800 600;
    let a : App :=
        app_set_frames
            (app_set_renderer (app_set_initial_world app_new meshed_world) r)
            1;
    let _ <- app_run a;
    let recorded <- renderer_recorded r;
    let sh : Shared (List RenderCommand) := Shared.of recorded;
    // clear + camera + 1 draw + present
    return (I64.beq (List.length (Shared.get sh)) 4 && I64.beq (count_draws (Shared.get sh)) 1)
}

/// The command ORDER the extract contract promises, on one frame.
#[test]
def test_frame_command_order : IO Bool := do {
    let r <- soft_renderer 800 600;
    let a : App :=
        app_set_frames
            (app_set_renderer (app_set_initial_world app_new meshed_world) r)
            1;
    let _ <- app_run a;
    let recorded <- renderer_recorded r;
    let get_kind : I64 -> I64 :=
        fn (i : I64) =>
            match List.get i recorded {
                Option.some c => command_kind c,
                Option.none => 0 - 1
            };
    // 0 = clear, 1 = set_camera, 2 = draw, 3 = present
    return (I64.beq (get_kind 0) 0 && I64.beq (get_kind 1) 1
                && I64.beq (get_kind 2) 2 && I64.beq (get_kind 3) 3)
}

/// Two frames of a one-mesh world: eight commands, two draws.
#[test]
def test_two_frames_record_eight_commands : IO Bool := do {
    let r <- soft_renderer 800 600;
    let a : App :=
        app_set_frames
            (app_set_renderer (app_set_initial_world app_new meshed_world) r)
            2;
    let _ <- app_run a;
    let recorded <- renderer_recorded r;
    let sh : Shared (List RenderCommand) := Shared.of recorded;
    return (I64.beq (List.length (Shared.get sh)) 8 && I64.beq (count_draws (Shared.get sh)) 2)
}

#[test]
def test_plugins_are_recorded_on_the_app : IO Bool := do {
    let p : Plugin := plugin_named "physics";
    let a : App := app_add_plugin app_new p;
    match List.first (app_plugin_names a) {
        Option.some n => return (String.beq n "physics"),
        Option.none => return (false)
    }
}

/// A headless run does no recording but still returns the advanced world.
#[test]
def test_headless_run_still_advances_the_world : IO Bool := do {
    let a : App := app_set_frames (app_set_initial_world app_new meshed_world) 1;
    let r : Renderer := app_renderer a;
    let w <- app_run a;
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) 0
                && I64.beq (world_entity_count w) 1)
}
