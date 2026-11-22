// forge-render: `extract` -- the pure `World -> List RenderCommand` pass.
// Phase 8, see ../../../PLAN.md.
//
// This is the seam the whole phase exists for: `extract` reads a `World` and
// produces commands, and NO backend type appears here. It runs at the
// `render_s` stage, on a `World` forge-scene has already propagated.
//
// An entity is drawn if it carries BOTH `forge.mesh` and a `GlobalTransform`:
// the mesh says what, the global says where. A `Camera` value (passed in, not
// stored) supplies the view-projection, emitted as one `set_camera_cmd`.

use std::derive {derive_copy, derive_clone, derive_debug}
use std::list {}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {Entity, World, get_component_named, insert_component}
use forge_core::query {query_entities}
use forge_math::{Mat4}
use forge_scene::{entity_global}
use lib::command {
    RenderCommand, Color, Camera, MeshHandle, MaterialHandle,
    clear, set_camera, set_light, draw_mesh, present_cmd_unit
}
use lib::light {world_light_opt}

// ── Mesh component ──────────────────────────────────────────────────

/// What an entity draws. Stored as an `Any`-boxed component value; `Copy`, so
/// unboxing it and reading it are both free.
#[derive Copy Clone Debug]
pub struct MeshComponent {
    mesh : MeshHandle,
    material : MaterialHandle
}

pub def mesh_component (mesh : MeshHandle) (material : MaterialHandle) : MeshComponent :=
    { mesh := mesh, material := material : MeshComponent }

pub def mesh_component_mesh (m : MeshComponent) : MeshHandle := m.mesh

pub def mesh_component_material (m : MeshComponent) : MaterialHandle := m.material

pub def mesh_name : String := "forge.mesh"

/// Attach a mesh to an entity.
pub def set_mesh (world : World) (e : Entity) (m : MeshComponent) : World :=
    insert_component world e mesh_name (Any.any m)

// ── Unboxing ────────────────────────────────────────────────────────

def as_mesh (v : Any) : MeshComponent :=
    match v { Any.any x => let m : MeshComponent := x in m }

/// An entity's mesh component, if it has one.
pub def entity_mesh (world : World) (e : Entity) : Option MeshComponent :=
    match get_component_named world e mesh_name {
        Option.none => Option.none,
        Option.some v => Option.some (as_mesh v)
    }

// ── Extraction ──────────────────────────────────────────────────────

/// An entity that can be drawn: its mesh handle, its material, and its world
/// matrix.
#[derive Copy Clone Debug]
pub struct DrawItem {
    mesh : MeshHandle,
    material : MaterialHandle,
    model : Mat4
}

/// The draw item for `e`, if it has both a mesh and a global transform.
def draw_item_of (world : World) (e : Entity) : Option DrawItem :=
    match entity_mesh world e {
        Option.none => Option.none,
        Option.some mesh0 =>
            let mesh : MeshComponent := mesh0 in
            match entity_global world e {
                Option.none => Option.none,
                Option.some model =>
                    Option.some { mesh := mesh.mesh, material := mesh.material, model := model
                                  : DrawItem }
            }
    }

/// All drawable entities (those carrying a mesh AND a global transform), in
/// query order.
#[terminating]
def drawables_go (world : World) (es : List Entity) : List DrawItem :=
    match es {
        List.empty => [],
        List.cons e rest =>
            match draw_item_of world e {
                Option.none => drawables_go world rest,
                Option.some d => List.cons d (drawables_go world rest)
            }
    }

pub def drawables (world : World) : List DrawItem :=
    drawables_go world (query_entities world [mesh_name] [])

/// One `draw_mesh` command per drawable.
pub def draw_commands (world : World) : List RenderCommand :=
    List.map (fn (d : DrawItem) => draw_mesh d.mesh d.material d.model) (drawables world)

/// The world's light as a command, if it set one.
def light_commands (world : World) : List RenderCommand :=
    match world_light_opt world {
        Option.some l => [set_light l],
        Option.none => []
    }

/// A full frame's worth of commands: clear, set the camera, set the light
/// (only when the world has one), a draw per drawable, present. The ORDER
/// is the contract a backend relies on.
pub def extract (world : World) (camera : Camera) (background : Color) : List RenderCommand :=
    let head : List RenderCommand := List.append [clear background, set_camera camera] (light_commands world) in
    List.append head (List.append (draw_commands world) [present_cmd_unit])

/// The number of drawable entities.
pub def drawable_count (world : World) : I64 := List.length (drawables world)
