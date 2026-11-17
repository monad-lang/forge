// forge-render: the frame PLAN -- the shared core of every drawing backend.
// Phase 9a, see ../../../PLAN.md.
//
// `extract` gives a backend-neutral `List RenderCommand`. Turning that into
// pixels still needs decisions that have nothing to do with any graphics
// API: which clear colour wins, which camera a draw is under, what a mesh or
// material id resolves to, what happens to a draw whose mesh does not exist.
// `frame_plan` makes ALL of those decisions, purely, and hands a backend a
// `FramePlan` it only has to execute.
//
// That is what keeps backends honest with each other. The WebGL backend
// (forge-webgl) walks `plan_draws` and issues one `drawElements` each; the
// soft backend records the commands the plan was built from. Both see the
// same draws in the same order by construction, and this file is tested
// natively -- no browser needed to know what a frame will draw.

use std::derive {}
use std::list {}
use init::copy {Copy}
use init::clone {Clone}
use forge_math::{Mat4, mat4_identity, mat4_mul, mat4_inverse, Ray, screen_to_ray}
use lib::command {
    RenderCommand, Color, color_clear, Camera, camera_view, camera_projection,
    camera_view_projection, MeshHandle, MaterialHandle
}
use lib::mesh {MeshData}
use lib::material {
    Assets, assets_mesh, assets_material_or_default, Material, ShaderKind, TextureHandle
}

/// One resolved draw: a mesh that EXISTS, the shader and tint to use, the
/// texture (or `texture_none`) and the model matrix. All-`Copy`.
#[derive Copy Clone Debug]
pub struct DrawCall {
    mesh : I64,
    shader : ShaderKind,
    tint : Color,
    texture : TextureHandle,
    model : Mat4
}

pub def draw_call_mesh (d : DrawCall) : I64 := d.mesh

pub def draw_call_shader (d : DrawCall) : ShaderKind := d.shader

pub def draw_call_tint (d : DrawCall) : Color := d.tint

pub def draw_call_texture (d : DrawCall) : TextureHandle := d.texture

pub def draw_call_model (d : DrawCall) : Mat4 := d.model

/// A whole frame, resolved. `Copy` is the hand-written identity (the draw
/// list is an immutable list).
///
/// - `clears`  : whether a `clear` command was seen (and `clear` its colour).
/// - `view`/`projection` : from the LAST `set_camera` before the draws.
/// - `draws`   : in command order.
/// - `skipped` : draws dropped because their mesh id is not in `Assets`.
/// - `presents`: whether the frame ends in a `present`.
pub struct FramePlan {
    clears : Bool,
    clear : Color,
    view : Mat4,
    projection : Mat4,
    draws : List DrawCall,
    skipped : I64,
    presents : Bool
}

pub instance Copy FramePlan {
    def copy (p : FramePlan) : Pair FramePlan FramePlan := Pair.pair p p
}

pub def plan_empty : FramePlan :=
    { clears := false,
      clear := color_clear,
      view := mat4_identity,
      projection := mat4_identity,
      draws := [],
      skipped := 0,
      presents := false
      : FramePlan }

pub def plan_clears (p : FramePlan) : Bool := p.clears

pub def plan_clear_color (p : FramePlan) : Color := p.clear

pub def plan_view (p : FramePlan) : Mat4 := p.view

pub def plan_projection (p : FramePlan) : Mat4 := p.projection

pub def plan_view_projection (p : FramePlan) : Mat4 := mat4_mul p.projection p.view

pub def plan_draws (p : FramePlan) : List DrawCall := p.draws

pub def plan_draw_count (p : FramePlan) : I64 := List.length p.draws

pub def plan_skipped (p : FramePlan) : I64 := p.skipped

pub def plan_presents (p : FramePlan) : Bool := p.presents

/// Resolve one draw against the tables: `none` when the mesh is unknown, the
/// default material when the material is.
pub def resolve_draw (assets : Assets) (mesh : MeshHandle) (material : MaterialHandle) (model : Mat4)
    : Option DrawCall :=
    match assets_mesh assets mesh.id {
        Option.none => Option.none,
        Option.some _ =>
            let m : Material := assets_material_or_default assets material.id in
            Option.some
                { mesh := mesh.id, shader := m.shader, tint := m.tint, texture := m.texture,
                  model := model
                  : DrawCall }
    }

def plan_with_draw (p : FramePlan) (d : Option DrawCall) : FramePlan :=
    match d {
        Option.some call => { p with draws := List.cons call p.draws },
        Option.none => { p with skipped := I64.add p.skipped 1 }
    }

/// Fold one command into the plan. Draws accumulate REVERSED (a cons per
/// draw) and `frame_plan` flips them once at the end.
def plan_step (assets : Assets) (p : FramePlan) (cmd : RenderCommand) : FramePlan :=
    match cmd {
        RenderCommand.clear_cmd c => { p with clears := true, clear := c },
        RenderCommand.set_camera_cmd cam =>
            let c : Camera := cam in
            { p with view := camera_view c, projection := camera_projection c },
        RenderCommand.draw_mesh_cmd mesh material model =>
            plan_with_draw p (resolve_draw assets mesh material model),
        RenderCommand.present_cmd => { p with presents := true }
    }

#[terminating]
def plan_go (assets : Assets) (p : FramePlan) (cmds : List RenderCommand) : FramePlan :=
    match cmds {
        List.empty => p,
        List.cons c rest => plan_go assets (plan_step assets p c) rest
    }

/// Resolve a frame's commands against `assets`.
pub def frame_plan (assets : Assets) (cmds : List RenderCommand) : FramePlan :=
    let folded : FramePlan := plan_go assets plan_empty cmds in
    { folded with draws := List.reverse folded.draws }

// ── Picking support ─────────────────────────────────────────────────

/// The world-space ray under pixel `(x, y)` of a `width` x `height` surface
/// (top-left origin), or `none` when the camera's view-projection cannot be
/// inverted.
pub def camera_screen_ray (camera : Camera) (width : F64) (height : F64) (x : F64) (y : F64)
    : Option Ray :=
    match mat4_inverse (camera_view_projection camera) {
        Option.none => Option.none,
        Option.some inv => Option.some (screen_to_ray inv width height x y)
    }
