// Mo Venture: what things look like, and spawning a level into a world.
//
// Three unit meshes (a cube, a sphere, a cylinder) are scaled per entity by
// its `Transform`; colliders carry their own sizes, so a platform's box
// collider and its scaled cube always agree because both come from the
// same `Plat`.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, Spawned, empty_world, insert_component}
use forge_math {Vec3, vec3, v3_add, v3_scale, Quat, quat_identity, quat_mul, quat_from_axis_angle}
use forge_scene {transform_new, spawn_transform, spawn_transform_child}
use forge_render {
    Color, color_rgb, Assets, assets_empty, MeshAdded, MaterialAdded, assets_add_mesh, assets_add_material,
    mesh_cube, mesh_sphere, mesh_cylinder, material_flat, MeshHandle, MaterialHandle, MeshComponent,
    mesh_component, set_mesh
}
use forge_collide {collider, collider_trigger, shape_box, shape_sphere, set_collider}
use lib::level {Level, Plat, plat_top, kind_grass, kind_stone, kind_wood, kind_gold}
use lib::tune {mo_stand}
use lib::mo {mo_rest, set_mo, mo_shape, yaw_quat}

// ── Assets ──────────────────────────────────────────────────────────

/// Handles into the game's asset tables. `Copy`.
#[derive Copy Clone]
pub struct Looks {
    cube : MeshHandle,
    sphere : MeshHandle,
    cylinder : MeshHandle,
    grass : MaterialHandle,
    stone : MaterialHandle,
    wood : MaterialHandle,
    gold : MaterialHandle,
    blue : MaterialHandle,
    white : MaterialHandle,
    dark : MaterialHandle,
    yellow : MaterialHandle,
    spark : MaterialHandle,
    flag_off : MaterialHandle,
    flag_on : MaterialHandle,
    beacon : MaterialHandle
}

/// The asset tables and the handles into them. `Copy`.
pub struct Loaded {
    assets : Assets,
    looks : Looks
}

pub instance Copy Loaded {
    def copy (l : Loaded) : Pair Loaded Loaded := Pair.pair l l
}

pub def loaded_assets (l : Loaded) : Assets := l.assets

pub def loaded_looks (l : Loaded) : Looks := l.looks

def mat (a : Assets) (r : F64) (g : F64) (b : F64) : MaterialAdded :=
    assets_add_material a (material_flat (color_rgb r g b))

pub def load : Loaded :=
    let cube : MeshAdded := assets_add_mesh assets_empty (mesh_cube 0.5) in
    let sphere : MeshAdded := assets_add_mesh cube.assets (mesh_sphere 0.5 10 16) in
    let cyl : MeshAdded := assets_add_mesh sphere.assets (mesh_cylinder 0.5 1.0 16) in
    let grass : MaterialAdded := mat cyl.assets 0.36 0.74 0.32 in
    let stone : MaterialAdded := mat grass.assets 0.62 0.63 0.68 in
    let wood : MaterialAdded := mat stone.assets 0.72 0.52 0.32 in
    let gold : MaterialAdded := mat wood.assets 0.95 0.78 0.26 in
    let blue : MaterialAdded := mat gold.assets 0.22 0.5 1.0 in
    let white : MaterialAdded := mat blue.assets 0.97 0.97 0.97 in
    let dark : MaterialAdded := mat white.assets 0.14 0.15 0.2 in
    let yellow : MaterialAdded := mat dark.assets 1.0 0.86 0.2 in
    let spark : MaterialAdded := mat yellow.assets 1.0 0.92 0.35 in
    let flag_off : MaterialAdded := mat spark.assets 0.85 0.25 0.25 in
    let flag_on : MaterialAdded := mat flag_off.assets 0.25 0.9 0.4 in
    let beacon : MaterialAdded := mat flag_on.assets 0.35 0.9 0.95 in
    { assets := beacon.assets,
      looks := { cube := cube.handle, sphere := sphere.handle, cylinder := cyl.handle,
                 grass := grass.handle, stone := stone.handle, wood := wood.handle, gold := gold.handle,
                 blue := blue.handle, white := white.handle, dark := dark.handle, yellow := yellow.handle,
                 spark := spark.handle, flag_off := flag_off.handle, flag_on := flag_on.handle,
                 beacon := beacon.handle : Looks }
      : Loaded }

// ── Tags ────────────────────────────────────────────────────────────

/// A collectable spark. `Copy`.
#[derive Copy Clone]
pub struct Spark {
    value : I64
}

pub def spark_name : String := "mo.spark"

/// A checkpoint trigger: where Mo comes back, its order along the course,
/// and the flag to light when reached. `Copy`.
#[derive Copy Clone]
pub struct Post {
    respawn : Vec3,
    index : I64,
    flag : Entity,
    lit : MeshComponent
}

pub def post_name : String := "mo.checkpoint"

/// The goal trigger. `Copy`.
#[derive Copy Clone]
pub struct Goal {
    reached : Bool
}

pub def goal_name : String := "mo.goal"

/// Spin about +y at `speed` rad/s, after a fixed `tilt`. `Copy`.
#[derive Copy Clone]
pub struct Spin {
    speed : F64,
    tilt : Quat
}

pub def spin_name : String := "mo.spin"

// ── Spawning ────────────────────────────────────────────────────────

/// An entity with a transform and a mesh; the caller adds the rest.
def shown (w : World) (p : Vec3) (r : Quat) (s : Vec3) (m : MeshHandle) (mt : MaterialHandle) : Spawned :=
    let e : Spawned := spawn_transform w (transform_new p r s) in
    { world := set_mesh e.world e.entity (mesh_component m mt), entity := e.entity : Spawned }

def part (w : World) (parent : Entity) (p : Vec3) (s : Vec3) (m : MeshHandle) (mt : MaterialHandle) : World :=
    let e : Spawned := spawn_transform_child w (transform_new p quat_identity s) parent in
    set_mesh e.world e.entity (mesh_component m mt)

def plat_material (lk : Looks) (k : I64) : MaterialHandle :=
    if k == kind_stone then lk.stone
    else if k == kind_wood then lk.wood
    else if k == kind_gold then lk.gold
    else lk.grass

def spawn_plat (lk : Looks) (w : World) (p : Plat) : World :=
    let e : Spawned := shown w p.center quat_identity (v3_scale p.half 2.0) lk.cube (plat_material lk p.kind) in
    set_collider e.world e.entity (collider (shape_box p.half))

#[terminating]
def spawn_plats (lk : Looks) (w : World) (ps : List Plat) : World :=
    match ps {
        List.empty => w,
        List.cons p rest => spawn_plats lk (spawn_plat lk w p) rest
    }

def spark_tilt : Quat :=
    quat_mul (quat_from_axis_angle (vec3 1.0 0.0 0.0) 0.6154797) (quat_from_axis_angle (vec3 0.0 0.0 1.0) 0.7853982)

def spawn_spark (lk : Looks) (w : World) (p : Vec3) : World :=
    let e : Spawned := shown w p spark_tilt (vec3 0.32 0.32 0.32) lk.cube lk.spark in
    let w1 : World := set_collider e.world e.entity (collider_trigger (shape_sphere 0.5)) in
    let w2 : World := insert_component w1 e.entity spin_name (Any.any { speed := 2.5, tilt := spark_tilt : Spin }) in
    insert_component w2 e.entity spark_name (Any.any { value := 1 : Spark })

#[terminating]
def spawn_sparks (lk : Looks) (w : World) (ps : List Vec3) : World :=
    match ps {
        List.empty => w,
        List.cons p rest => spawn_sparks lk (spawn_spark lk w p) rest
    }

/// A checkpoint at platform-top point `p`: a trigger across the platform,
/// a post 1.8 to the side with a flag that lights when reached.
def spawn_post (lk : Looks) (w : World) (p : Vec3) (index : I64) : World :=
    let pole : Spawned := shown w (v3_add p (vec3 1.8 1.0 0.0)) quat_identity (vec3 0.12 2.0 0.12) lk.cylinder lk.white in
    let flag : Spawned := shown pole.world (v3_add p (vec3 2.15 1.75 0.0)) quat_identity (vec3 0.6 0.4 0.05)
                                lk.cube lk.flag_off in
    let trig : Spawned := spawn_transform flag.world (transform_new (v3_add p (vec3 0.0 1.0 0.0)) quat_identity (vec3 1.0 1.0 1.0)) in
    let w1 : World := set_collider trig.world trig.entity (collider_trigger (shape_box (vec3 2.5 1.0 0.6))) in
    let post : Post := { respawn := v3_add p (vec3 0.0 (mo_stand + 0.01) 0.0), index := index, flag := flag.entity,
                         lit := mesh_component lk.cube lk.flag_on : Post } in
    insert_component w1 trig.entity post_name (Any.any post)

#[terminating]
def spawn_posts (lk : Looks) (w : World) (ps : List Vec3) (index : I64) : World :=
    match ps {
        List.empty => w,
        List.cons p rest => spawn_posts lk (spawn_post lk w p index) rest (index + 1)
    }

/// The goal at platform-top point `p`: a glowing pad, a gold cube spinning
/// above it, and a trigger around both.
def spawn_goal (lk : Looks) (w : World) (p : Vec3) : World :=
    let pad : Spawned := shown w (v3_add p (vec3 0.0 0.05 0.0)) quat_identity (vec3 2.2 0.1 2.2) lk.cylinder lk.beacon in
    let gem : Spawned := shown pad.world (v3_add p (vec3 0.0 2.0 0.0)) spark_tilt (vec3 0.7 0.7 0.7) lk.cube lk.gold in
    let w1 : World := insert_component gem.world gem.entity spin_name (Any.any { speed := 1.5, tilt := spark_tilt : Spin }) in
    let trig : Spawned := spawn_transform w1 (transform_new (v3_add p (vec3 0.0 1.5 0.0)) quat_identity (vec3 1.0 1.0 1.0)) in
    let w2 : World := set_collider trig.world trig.entity (collider_trigger (shape_box (vec3 1.2 1.5 1.2))) in
    insert_component w2 trig.entity goal_name (Any.any { reached := false : Goal })

/// Mo at ground point `p`: a blue body with white eyes, dark feet and a
/// little antenna, facing -z. The root carries the capsule and the state;
/// the parts are children, offset in Mo's frame (+z is Mo's front).
pub def spawn_mo (lk : Looks) (w : World) (p : Vec3) : Spawned :=
    let face : Vec3 := vec3 0.0 0.0 (0.0 - 1.0) in
    let root : Spawned := spawn_transform w (transform_new (v3_add p (vec3 0.0 (mo_stand + 0.01) 0.0)) (yaw_quat face) (vec3 1.0 1.0 1.0)) in
    let e : Entity := root.entity in
    let w1 : World := set_mo (set_collider root.world e (collider mo_shape)) e mo_rest in
    let w2 : World := part w1 e (vec3 0.0 (0.0 - 0.12) 0.0) (vec3 1.0 1.0 1.0) lk.sphere lk.blue in
    let w3 : World := part w2 e (vec3 0.16 0.1 0.44) (vec3 0.12 0.2 0.06) lk.cube lk.white in
    let w4 : World := part w3 e (vec3 (0.0 - 0.16) 0.1 0.44) (vec3 0.12 0.2 0.06) lk.cube lk.white in
    let w5 : World := part w4 e (vec3 0.2 (0.0 - 0.62) 0.06) (vec3 0.24 0.14 0.34) lk.cube lk.dark in
    let w6 : World := part w5 e (vec3 (0.0 - 0.2) (0.0 - 0.62) 0.06) (vec3 0.24 0.14 0.34) lk.cube lk.dark in
    let w7 : World := part w6 e (vec3 0.0 0.5 0.0) (vec3 0.05 0.3 0.05) lk.cylinder lk.dark in
    { world := part w7 e (vec3 0.0 0.7 0.0) (vec3 0.18 0.18 0.18) lk.sphere lk.yellow, entity := e : Spawned }

/// A whole level in a fresh world, with Mo at the start.
pub def level_world (lk : Looks) (lv : Level) : World :=
    let w1 : World := spawn_plats lk empty_world lv.plats in
    let w2 : World := spawn_sparks lk w1 lv.sparks in
    let w3 : World := spawn_posts lk w2 lv.posts 1 in
    let w4 : World := spawn_goal lk w3 lv.goal in
    let mo : Spawned := spawn_mo lk w4 lv.start in
    mo.world
