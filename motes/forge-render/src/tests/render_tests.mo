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
    renderer_is_recording, renderer_resize, renderer_size, renderer_shutdown,
    Assets, assets_empty, MeshAdded, MaterialAdded, assets_add_mesh, assets_add_material,
    material_flat, material_textured, texture_handle, texture_is_none, shader_kind_code,
    mesh_cube, mesh_quad, color_white, color,
    FramePlan, DrawCall, frame_plan, plan_draws, plan_draw_count, plan_skipped,
    plan_clears, plan_presents, plan_clear_color, plan_view, draw_call_mesh,
    draw_call_shader, draw_call_model, draw_call_texture, color_r,
    clear, set_camera, draw_mesh, camera_screen_ray,
    Picked, picked_entity, picked_distance, pick_entity,
    material_unlit, draw_call_unlit, plan_light, plan_shadows, plan_casters,
    Light, light_sun, light_default, light_with_shadows, light_toward, light_ambient, world_set_light
}
use forge_core::ecs {World, Spawned, Entity, empty_world}
use forge_math::{
    vec3, Vec3, mat4_identity, Mat4, mat4_translate, mat4_translation, mat4_perspective,
    mat4_look_at, Ray, ray, f64_abs
}
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

// ── Phase 9a: assets, the frame plan, picking ───────────────────────

/// One cube mesh (handle 1) and one flat material (handle 1) -- the ids
/// `spawn_mesh_entity` above already uses.
def cube_assets : Assets :=
    let m : MeshAdded := assets_add_mesh assets_empty (mesh_cube 1.0) in
    let mat : MaterialAdded := assets_add_material m.assets (material_flat (color 1.0 0.0 0.0 1.0)) in
    mat.assets

def two_cube_world : World :=
    let a : Spawned := spawn_mesh_entity empty_world 0.0 in
    let b : Spawned := spawn_mesh_entity a.world 5.0 in
    propagate_transforms b.world

#[test]
def test_plan_of_an_empty_frame : Bool :=
    let p : FramePlan := frame_plan cube_assets (extract empty_world camera_stub color_black) in
    plan_clears p && plan_presents p && I64.beq (plan_draw_count p) 0 && I64.beq (plan_skipped p) 0

#[test]
def test_plan_draw_count_matches_the_commands : Bool :=
    let cmds : List RenderCommand := extract two_cube_world camera_stub color_black in
    let sh : Shared (List RenderCommand) := Shared.of cmds in
    let p : FramePlan := frame_plan cube_assets (Shared.get sh) in
    I64.beq (plan_draw_count p) (count_draws (Shared.get sh)) && I64.beq (plan_draw_count p) 2

def draw_x (o : Option DrawCall) : F64 :=
    match o {
        Option.some d =>
            let t : Vec3 := mat4_translation (draw_call_model d) in
            t.x,
        Option.none => 0.0 - 1.0
    }

#[test]
def test_plan_keeps_command_order : Bool :=
    let p : FramePlan := frame_plan cube_assets (extract two_cube_world camera_stub color_black) in
    let sh : Shared (List DrawCall) := Shared.of (plan_draws p) in
    F64.beq (draw_x (List.get 0 (Shared.get sh))) 0.0 && F64.beq (draw_x (List.get 1 (Shared.get sh))) 5.0

#[test]
def test_plan_skips_a_draw_whose_mesh_is_unknown : Bool :=
    // No mesh was ever added, so both draws are dropped and counted.
    let p : FramePlan := frame_plan assets_empty (extract two_cube_world camera_stub color_black) in
    I64.beq (plan_draw_count p) 0 && I64.beq (plan_skipped p) 2

#[test]
def test_plan_resolves_the_material : Bool :=
    let m : MeshAdded := assets_add_mesh assets_empty (mesh_quad 1.0 1.0) in
    let mat : MaterialAdded :=
        assets_add_material m.assets (material_textured (texture_handle 3) color_white) in
    let p : FramePlan :=
        frame_plan mat.assets [draw_mesh m.handle mat.handle mat4_identity] in
    match List.first (plan_draws p) {
        Option.some d0 =>
            let d : DrawCall := d0 in
            I64.beq (shader_kind_code (draw_call_shader d)) 1
                && Bool.not (texture_is_none (draw_call_texture d))
                && I64.beq (draw_call_mesh d) 1,
        Option.none => false
    }

#[test]
def test_plan_unknown_material_uses_the_default : Bool :=
    let m : MeshAdded := assets_add_mesh assets_empty (mesh_quad 1.0 1.0) in
    let p : FramePlan :=
        frame_plan m.assets [draw_mesh m.handle (material_handle 77) mat4_identity] in
    match List.first (plan_draws p) {
        Option.some d0 =>
            let d : DrawCall := d0 in
            I64.beq (shader_kind_code (draw_call_shader d)) 0 && texture_is_none (draw_call_texture d),
        Option.none => false
    }

#[test]
def test_plan_takes_the_clear_colour_and_camera : Bool :=
    let cam : Camera :=
        camera_new (mat4_translate (vec3 0.0 0.0 (0.0 - 9.0))) mat4_identity (vec3 0.0 0.0 9.0) in
    let p : FramePlan := frame_plan assets_empty [clear (color 0.25 0.5 0.75 1.0), set_camera cam] in
    let t : Vec3 := mat4_translation (plan_view p) in
    F64.beq (color_r (plan_clear_color p)) 0.25 && F64.beq t.z (0.0 - 9.0)
        && Bool.not (plan_presents p)

#[test]
def test_soft_recording_and_plan_agree : IO Bool := do {
    // The parity statement: what the recording backend saw and what a drawing
    // backend is told to draw are the same draws.
    let cmds : List RenderCommand := extract two_cube_world camera_stub color_black;
    let sh : Shared (List RenderCommand) := Shared.of cmds;
    let r <- soft_renderer 800 600;
    renderer_submit r (Shared.get sh);
    let recorded <- renderer_recorded r;
    let p : FramePlan := frame_plan cube_assets (Shared.get sh);
    return (I64.beq (count_draws recorded) (plan_draw_count p))
}

/// A camera at (0,0,10) looking at the origin.
def pick_camera : Camera :=
    camera_new (mat4_look_at (vec3 0.0 0.0 10.0) (vec3 0.0 0.0 0.0) (vec3 0.0 1.0 0.0))
               (mat4_perspective 1.0 (800.0 / 600.0) 0.1 100.0)
               (vec3 0.0 0.0 10.0)

def pick_at (x : F64) (y : F64) : Option Picked :=
    match camera_screen_ray pick_camera 800.0 600.0 x y {
        Option.some r => pick_entity two_cube_world cube_assets r,
        Option.none => Option.none
    }

#[test]
def test_camera_screen_ray_center_points_at_the_target : Bool :=
    match camera_screen_ray pick_camera 800.0 600.0 400.0 300.0 {
        Option.some r0 =>
            let r : Ray := r0 in
            r.direction.z < (0.0 - 0.9999),
        Option.none => false
    }

#[test]
def test_pick_center_hits_the_cube_at_the_origin : Bool :=
    match pick_at 400.0 300.0 {
        Option.some p0 =>
            let p : Picked := p0 in
            // near plane at z = 9.9, cube face at z = 1.
            f64_abs (picked_distance p - 8.9) < 0.001,
        Option.none => false
    }

#[test]
def test_pick_a_corner_hits_nothing : Bool :=
    match pick_at 2.0 2.0 {
        Option.some _ => false,
        Option.none => true
    }

#[test]
def test_pick_takes_the_nearest_of_two : Bool :=
    // A ray along +x from far left passes through BOTH cubes (x = 0 and
    // x = 5); the one at the origin is entered first, at x = -1.
    match pick_entity two_cube_world cube_assets (ray (vec3 (0.0 - 10.0) 0.0 0.0) (vec3 1.0 0.0 0.0)) {
        Option.some p0 =>
            let p : Picked := p0 in
            f64_abs (picked_distance p - 9.0) < 0.001,
        Option.none => false
    }

#[test]
def test_pick_with_no_assets_hits_nothing : Bool :=
    match pick_entity two_cube_world assets_empty (ray (vec3 (0.0 - 10.0) 0.0 0.0) (vec3 1.0 0.0 0.0)) {
        Option.some _ => false,
        Option.none => true
    }

// ── Light ───────────────────────────────────────────────────────────

/// A world without a light extracts no `set_light`, and the plan falls back
/// to the default sun with no shadow pass.
#[test]
def test_plan_without_a_light_uses_the_default : Bool :=
    let cmds : List RenderCommand := extract two_cube_world camera_stub color_black in
    let sh : Shared (List RenderCommand) := Shared.of cmds in
    let p : FramePlan := frame_plan cube_assets (Shared.get sh) in
    let l : Light := plan_light p in
    let t : Vec3 := light_toward l in
    I64.beq (List.length (Shared.get sh)) 5 && Bool.not (plan_shadows p) && t.y > 0.8

#[test]
def test_plan_takes_the_worlds_light : Bool :=
    let sun : Light := light_with_shadows (light_sun (vec3 0.0 1.0 0.0) (vec3 1.0 0.9 0.8) 0.7 0.25) 15.0 50.0 1024 in
    let p : FramePlan := frame_plan cube_assets (extract (world_set_light two_cube_world sun) camera_stub color_black) in
    let l : Light := plan_light p in
    plan_shadows p && f64_abs (light_ambient l - 0.25) < 0.000001 && I64.beq (plan_draw_count p) 2

/// Unlit draws are drawn but cast no shadow.
#[test]
def test_unlit_draws_cast_no_shadow : Bool :=
    let m : MeshAdded := assets_add_mesh assets_empty (mesh_cube 0.5) in
    let lit : MaterialAdded := assets_add_material m.assets (material_flat color_white) in
    let glow : MaterialAdded := assets_add_material lit.assets (material_unlit color_white) in
    let p : FramePlan :=
        frame_plan glow.assets [draw_mesh m.handle lit.handle mat4_identity, draw_mesh m.handle glow.handle mat4_identity] in
    let unlit_second : Bool := match List.get 1 (plan_draws p) {
        Option.some d => draw_call_unlit d,
        Option.none => false
    } in
    I64.beq (plan_draw_count p) 2 && I64.beq (List.length (plan_casters p)) 1 && unlit_second
