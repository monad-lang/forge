// forge-render: picking -- which drawn entity is under a ray. Phase 9a, see
// ../../../PLAN.md.
//
// A pick is the nearest hit of a world-space ray against each drawable's
// LOCAL bounding box: the ray is carried into the mesh's space with the
// inverse model matrix, tested with forge-math's slab test, and the hit is
// carried back out so distances compare in world units. It reads the same
// things `extract` reads (a mesh component and a `GlobalTransform`), so "can
// be picked" and "is drawn" are the same set.
//
// Bounding boxes, not triangles: exact for boxes and quads, conservative for
// discs and cylinders. That is the right trade for a board game's tokens.

use std::derive {}
use std::list {}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {Entity, World}
use forge_core::query {query_entities}
use forge_math::{
    Vec3, v3_add, v3_scale, v3_normalize, v3_distance, Mat4, mat4_inverse,
    mat4_transform_point, mat4_transform_dir, Ray, ray, AABB, ray_aabb_hit
}
use forge_scene::{entity_global}
use lib::extract {MeshComponent, entity_mesh, mesh_name}
use lib::mesh {MeshData, mesh_bounds}
use lib::material {Assets, assets_mesh}

/// A picked entity and how far along the ray it was hit (world units).
#[derive Copy Clone Debug]
pub struct Picked {
    entity : Entity,
    distance : F64
}

pub def picked_entity (p : Picked) : Entity := p.entity

pub def picked_distance (p : Picked) : F64 := p.distance

/// The world-space distance at which `r` enters `bounds` placed by `model`.
pub def ray_hits_placed_box (r : Ray) (model : Mat4) (bounds : AABB) : Option F64 :=
    match mat4_inverse model {
        Option.none => Option.none,
        Option.some inv0 =>
            let inv : Mat4 := inv0 in
            let origin : Vec3 := mat4_transform_point inv r.origin in
            let dir : Vec3 := v3_normalize (mat4_transform_dir inv r.direction) in
            match ray_aabb_hit (ray origin dir) bounds {
                Option.none => Option.none,
                Option.some t =>
                    let local_hit : Vec3 := v3_add origin (v3_scale dir t) in
                    Option.some (v3_distance (mat4_transform_point model local_hit) r.origin)
            }
    }

/// The hit distance for one entity, if it is drawable, known, and under the ray.
def entity_hit (world : World) (assets : Assets) (r : Ray) (e : Entity) : Option F64 :=
    match entity_mesh world e {
        Option.none => Option.none,
        Option.some mc0 =>
            let mc : MeshComponent := mc0 in
            match assets_mesh assets mc.mesh.id {
                Option.none => Option.none,
                Option.some data =>
                    match entity_global world e {
                        Option.none => Option.none,
                        Option.some model => ray_hits_placed_box r model (mesh_bounds data)
                    }
            }
    }

def nearer (best : Option Picked) (e : Entity) (hit : Option F64) : Option Picked :=
    match hit {
        Option.none => best,
        Option.some d0 =>
            let d : F64 := d0 in
            match best {
                Option.none => Option.some { entity := e, distance := d : Picked },
                Option.some b0 =>
                    let b : Picked := b0 in
                    if d < b.distance
                    then Option.some { entity := e, distance := d : Picked }
                    else Option.some b
            }
    }

#[terminating]
def pick_go (world : World) (assets : Assets) (r : Ray) (es : List Entity) (best : Option Picked)
    : Option Picked :=
    match es {
        List.empty => best,
        List.cons e rest => pick_go world assets r rest (nearer best e (entity_hit world assets r e))
    }

/// The nearest drawable entity under `r`, if any. Run it on a world whose
/// transforms are propagated (the one a frame returns).
pub def pick_entity (world : World) (assets : Assets) (r : Ray) : Option Picked :=
    pick_go world assets r (query_entities world [mesh_name] []) Option.none
