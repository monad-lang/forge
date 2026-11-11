// forge-render integration tests, over the PUBLIC surface (`lib::{...}`).
//
// The point of these is the WHOLE pipeline with no GPU: build a scene, extract
// a command list, hand it to the soft backend, and assert what was recorded.

use lib::{
    MeshHandle, mesh_handle, mesh_handle_id,
    MaterialHandle, material_handle, Color, color_black,
    Camera, camera_new, RenderCommand, command_kind, count_draws, present_cmd_unit,
    MeshComponent, mesh_component, mesh_component_mesh, mesh_name, set_mesh,
    entity_mesh, draw_commands, extract, drawable_count,
    Renderer, soft_renderer, headless_renderer, renderer_submit, renderer_recorded,
    renderer_is_recording, renderer_resize, renderer_size, renderer_shutdown
}
use forge_core::ecs {World, Spawned, Entity, empty_world}
use forge_math::{vec3, mat4_identity}
use forge_scene::{spawn_transform, transform_from_translation, propagate_transforms}

def camera_stub : Camera :=
    camera_new mat4_identity mat4_identity (vec3 0.0 0.0 0.0)

/// Spawn a transformed entity and give it a mesh.
def spawn_mesh_entity (world : World) (x : F64) : Spawned :=
    let s : Spawned := spawn_transform world (transform_from_translation (vec3 x 0.0 0.0)) in
    { world := set_mesh s.world s.entity (mesh_component (mesh_handle 1) (material_handle 1)),
      entity := s.entity
      : Spawned }

#[test]
def test_extract_on_an_empty_world_is_clear_camera_present : Bool :=
    I64.beq (List.length (extract empty_world camera_stub color_black)) 3

#[test]
def test_extract_head_is_clear_then_camera : Bool :=
    let cmds : List RenderCommand := extract empty_world camera_stub color_black in
    let sh : Shared (List RenderCommand) := Shared.of cmds in
    I64.beq (command_kind (option_get_or_0 (List.get 0 (Shared.get sh)))) 0
        && I64.beq (command_kind (option_get_or_0 (List.get 1 (Shared.get sh)))) 1

def option_get_or_0 (o : Option RenderCommand) : RenderCommand :=
    match o {
        Option.some c => c,
        Option.none => present_command_fallback
    }

def present_command_fallback : RenderCommand := present_cmd_fallback

def present_cmd_fallback : RenderCommand := present_cmd_unit

#[test]
def test_extract_tail_is_present : Bool :=
    let cmds : List RenderCommand := extract empty_world camera_stub color_black in
    I64.beq (command_kind (option_last (List.last cmds))) 3

def option_last (o : Option RenderCommand) : RenderCommand :=
    match o {
        Option.some c => c,
        Option.none => present_cmd_fallback
    }

#[test]
def test_one_meshed_entity_yields_one_draw : Bool :=
    let s : Spawned := spawn_mesh_entity empty_world 0.0 in
    I64.beq (drawable_count (propagate_transforms s.world)) 1

#[test]
def test_two_meshed_entities_yield_two_draws : Bool :=
    let a : Spawned := spawn_mesh_entity empty_world 0.0 in
    let b : Spawned := spawn_mesh_entity a.world 5.0 in
    I64.beq (drawable_count (propagate_transforms b.world)) 2

#[test]
def test_extract_length_with_two_drawables : Bool :=
    let a : Spawned := spawn_mesh_entity empty_world 0.0 in
    let b : Spawned := spawn_mesh_entity a.world 5.0 in
    let cmds : List RenderCommand := extract (propagate_transforms b.world) camera_stub color_black in
    // clear + camera + 2 draws + present
    I64.beq (List.length cmds) 5

#[test]
def test_draw_commands_are_all_draws : Bool :=
    let s : Spawned := spawn_mesh_entity empty_world 0.0 in
    let cmds : List RenderCommand := draw_commands (propagate_transforms s.world) in
    let sh : Shared (List RenderCommand) := Shared.of cmds in
    I64.beq (List.length (Shared.get sh)) 1 && I64.beq (count_draws (Shared.get sh)) 1

#[test]
def test_entity_mesh_roundtrips : Bool :=
    let s : Spawned := spawn_mesh_entity empty_world 0.0 in
    match entity_mesh s.world s.entity {
        Option.some m => I64.beq (mesh_handle_id (mesh_component_mesh m)) 1,
        Option.none => false
    }

#[test]
def test_an_entity_without_a_mesh_is_not_drawn : Bool :=
    let s : Spawned := spawn_transform empty_world (transform_from_translation (vec3 0.0 0.0 0.0)) in
    I64.beq (drawable_count (propagate_transforms s.world)) 0

#[test]
def test_soft_backend_records_a_frame : IO Bool := do {
    let s : Spawned := spawn_mesh_entity empty_world 0.0;
    let r <- soft_renderer 800 600;
    let cmds : List RenderCommand := extract (propagate_transforms s.world) camera_stub color_black;
    renderer_submit r cmds;
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) 4 && renderer_is_recording r)
}

#[test]
def test_headless_backend_records_nothing : IO Bool := do {
    renderer_submit headless_renderer [present_cmd_fallback];
    let recorded <- renderer_recorded headless_renderer;
    return (I64.beq (List.length recorded) 0 && Bool.not (renderer_is_recording headless_renderer))
}

#[test]
def test_soft_backend_resize : IO Bool := do {
    let r <- soft_renderer 800 600;
    renderer_resize r 1024 768;
    let wh <- renderer_size r;
    match wh {
        Pair.pair w h => return (I64.beq w 1024 && I64.beq h 768)
    }
}

#[test]
def test_soft_backend_shutdown_clears : IO Bool := do {
    let r <- soft_renderer 10 10;
    renderer_submit r [present_cmd_fallback];
    renderer_shutdown r;
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) 0)
}
