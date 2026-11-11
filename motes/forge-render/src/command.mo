// forge-render: the backend-agnostic render vocabulary. Phase 8, see
// ../../../PLAN.md.
//
// The point of this whole module is that the CORE never knows which backend
// draws: `extract` turns a `World` into a pure `List RenderCommand`, and a
// `Renderer` consumes that list. MLIR/GPU and WebGL become additional
// `Renderer`s without the core changing.
//
// Every type here is a monomorphic `Copy` struct or a payload-carrying `Copy`
// enum, so an `extract` pass reads its inputs as often as it likes and a
// command list is cheap to copy.

use std::derive {derive_copy, derive_clone, derive_debug}
use std::list {}
use init::copy {Copy}
use init::clone {Clone}
use forge_math::{Vec3, Mat4, mat4_identity, mat4_mul}

// ── Handles and colour ──────────────────────────────────────────────

/// An opaque mesh id. `Copy`.
#[derive Copy Clone BEq Debug]
pub struct MeshHandle {
    id : I64
}

pub def mesh_handle (i : I64) : MeshHandle := { id := i : MeshHandle }

pub def mesh_handle_id (h : MeshHandle) : I64 := h.id

/// An opaque material id. `Copy`.
#[derive Copy Clone BEq Debug]
pub struct MaterialHandle {
    id : I64
}

pub def material_handle (i : I64) : MaterialHandle := { id := i : MaterialHandle }

pub def material_handle_id (h : MaterialHandle) : I64 := h.id

/// Linear RGBA. `Copy`.
#[derive Copy Clone Debug]
pub struct Color {
    r : F64,
    g : F64,
    b : F64,
    a : F64
}

pub def color (r : F64) (g : F64) (b : F64) (a : F64) : Color :=
    { r := r, g := g, b := b, a := a : Color }

pub def color_rgb (r : F64) (g : F64) (b : F64) : Color := color r g b 1.0

pub def color_black : Color := color_rgb 0.0 0.0 0.0

pub def color_white : Color := color_rgb 1.0 1.0 1.0

pub def color_clear : Color := color 0.1 0.1 0.12 1.0

pub def color_r (c : Color) : F64 := c.r

pub def color_g (c : Color) : F64 := c.g

pub def color_b (c : Color) : F64 := c.b

pub def color_a (c : Color) : F64 := c.a

// ── Camera ──────────────────────────────────────────────────────────

/// A view-projection description. `Copy`.
#[derive Copy Clone Debug]
pub struct Camera {
    view : Mat4,
    projection : Mat4,
    position : Vec3
}

pub def camera_new (view : Mat4) (projection : Mat4) (position : Vec3) : Camera :=
    { view := view, projection := projection, position := position : Camera }

pub def camera_view (c : Camera) : Mat4 := c.view

pub def camera_projection (c : Camera) : Mat4 := c.projection

pub def camera_position (c : Camera) : Vec3 := c.position

/// The combined `projection * view`.
pub def camera_view_projection (c : Camera) : Mat4 := mat4_mul c.projection c.view

// ── Render commands ─────────────────────────────────────────────────

/// One thing to draw or set. Payload-carrying `Copy` enum: a `renderer`'s whole
/// input for a frame is a `List RenderCommand`.
#[derive Copy Clone Debug]
pub type RenderCommand {
    clear_cmd (color : Color),
    set_camera_cmd (camera : Camera),
    draw_mesh_cmd (mesh : MeshHandle) (material : MaterialHandle) (model : Mat4),
    present_cmd
}

pub def clear (c : Color) : RenderCommand := clear_cmd c

pub def set_camera (c : Camera) : RenderCommand := set_camera_cmd c

pub def draw_mesh (mesh : MeshHandle) (material : MaterialHandle) (model : Mat4) : RenderCommand :=
    draw_mesh_cmd mesh material model

pub def present_cmd_unit : RenderCommand := present_cmd

/// A command's sort tag, for tests and for a backend that wants to group.
pub def command_kind (cmd : RenderCommand) : I64 :=
    match cmd {
        clear_cmd _ => 0,
        set_camera_cmd _ => 1,
        draw_mesh_cmd _ _ _ => 2,
        present_cmd => 3
    }

pub def is_draw (cmd : RenderCommand) : Bool :=
    match cmd {
        draw_mesh_cmd _ _ _ => true,
        clear_cmd _ => false,
        set_camera_cmd _ => false,
        present_cmd => false
    }

/// Count the draw commands in a frame.
#[terminating]
def count_draws_go (cmds : List RenderCommand) (n : I64) : I64 :=
    match cmds {
        List.empty => n,
        List.cons c rest => count_draws_go rest (if is_draw c then I64.add n 1 else n)
    }

pub def count_draws (cmds : List RenderCommand) : I64 := count_draws_go cmds 0

#[test]
def test_color_components : Bool :=
    let c : Color := color 0.25 0.5 0.75 1.0 in
    let r : F64 := c.r in
    let g : F64 := c.g in
    let b : F64 := c.b in
    let a : F64 := c.a in
    F64.beq r 0.25 && F64.beq g 0.5 && F64.beq b 0.75 && F64.beq a 1.0

#[test]
def test_mesh_handle_roundtrip : Bool :=
    I64.beq (mesh_handle_id (mesh_handle 7)) 7

#[test]
def test_material_handle_roundtrip : Bool :=
    I64.beq (material_handle_id (material_handle 9)) 9

#[test]
def test_command_kinds : Bool :=
    I64.beq (command_kind (clear color_black)) 0
        && I64.beq (command_kind present_cmd_unit) 3

#[test]
def test_is_draw : Bool :=
    let cmd : RenderCommand :=
        draw_mesh (mesh_handle 1) (material_handle 2) mat4_identity in
    is_draw cmd

#[test]
def test_count_draws : Bool :=
    let cmds : List RenderCommand :=
        [clear color_black,
         draw_mesh (mesh_handle 1) (material_handle 1) mat4_identity,
         present_cmd_unit] in
    I64.beq (count_draws cmds) 1

#[test]
def test_clear_and_present_are_not_draws : Bool :=
    let cmds : List RenderCommand := [clear color_black, present_cmd_unit] in
    I64.beq (count_draws cmds) 0
