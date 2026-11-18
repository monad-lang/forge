// forge-app: picking. A screen ray hits colliders first (`forge_collide`'s
// `raycast`, exact for the collider shapes); a world without colliders
// falls back to forge-render's mesh bounds. Pure, so both the web host and
// native tests use it.

use forge_core::ecs {World, Entity, entity_id}
use forge_math {Ray}
use forge_render {Assets, Picked, pick_entity}
use forge_collide {Scene, Hit, collision_scene, scene_size, raycast, hit_entity, layer_all}

/// How far a pick ray reaches.
pub def pick_reach : F64 := 10000.0

def mesh_pick (world : World) (assets : Assets) (r : Ray) : I64 :=
    match pick_entity world assets r {
        Option.some p0 => let p : Picked := p0 in U64.to_i64 (entity_id p.entity),
        Option.none => 0 - 1
    }

def collider_pick (s : Scene) (r : Ray) : I64 :=
    match raycast s r pick_reach layer_all {
        Option.some h0 => let h : Hit := h0 in U64.to_i64 (entity_id (hit_entity h)),
        Option.none => 0 - 1
    }

/// The id of the entity under ray `r`, or -1: the nearest solid collider
/// when the world has any, else the nearest mesh bound.
pub def world_pick (world : World) (assets : Assets) (r : Ray) : I64 :=
    let s : Scene := collision_scene world in
    if scene_size s > 0 then collider_pick s r else mesh_pick world assets r
