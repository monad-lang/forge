// Mo Venture: what things look like, and spawning a level into a world.
//
// Three unit meshes (a cube, a sphere, a cylinder) are scaled per entity by
// its `Transform`; colliders carry their own sizes, so a platform's box
// collider and its scaled cube always agree because both come from the
// same `Plat`.
//
// Movers, the checkpoint flags and the goal gem move by forge-animate clips;
// the sun is an unlit disc kept far off along the light (`game.mo` moves
// it). Every level entity has a transform, so a level is cleared by
// despawning the transformed entities (`clear_level`).

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, Spawned, empty_world, insert_component, despawn}
use forge_core::query {query_entities}
use forge_math {Vec3, vec3, v3_add, v3_scale, Quat, quat_identity, quat_mul, quat_from_axis_angle, f64_of_i64}
use forge_scene {transform_new, transform_name, spawn_transform, spawn_transform_child, set_name, children_of}
use forge_animate {
    Easing, Property, key_vec3, key_quat, track, channel, Clip, clip, clip_timed, animator, animator_at,
    LoopMode, set_animator
}
use forge_render {
    Color, color_rgb, Assets, assets_empty, MeshAdded, MaterialAdded, assets_add_mesh, assets_add_material,
    mesh_cube, mesh_sphere, mesh_cylinder, material_flat, material_unlit, MeshHandle, MaterialHandle, MeshComponent,
    mesh_component, set_mesh
}
use forge_collide {
    collider, collider_trigger, collider_with_layers, layer_all, shape_box, shape_sphere, set_collider
}
use lib::level {
    Level, Plat, Switch, Gate, plat_top, kind_grass, kind_stone, kind_wood, kind_gold, kind_climb,
    mover_dwell, mover_travel, level_plats, level_climbs, level_boxes, level_switches, level_gates,
    switch_pos, switch_gate, gate_pos, gate_half, gate_id
}
use lib::tune {mo_stand}
use lib::hero {hero_xiaozhu, hero_xiaomao, hero_next, hero_name}
use lib::mo {
    mo_rest_for, set_mo, mo_shape, mo_move_layers, yaw_quat, carrier_name, carrier_at, body_name,
    player_name, companion_name, layer_world, layer_climb
}

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
    pink : MaterialHandle,
    snout : MaterialHandle,
    ginger : MaterialHandle,
    ginger_dark : MaterialHandle,
    green : MaterialHandle,
    white : MaterialHandle,
    dark : MaterialHandle,
    spark : MaterialHandle,
    flag_off : MaterialHandle,
    flag_on : MaterialHandle,
    beacon : MaterialHandle,
    sun : MaterialHandle
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
    let pink : MaterialAdded := mat gold.assets 1.0 0.68 0.75 in
    let snout : MaterialAdded := mat pink.assets 0.93 0.5 0.6 in
    let ginger : MaterialAdded := mat snout.assets 1.0 0.6 0.22 in
    let ginger_dark : MaterialAdded := mat ginger.assets 0.78 0.38 0.12 in
    let green : MaterialAdded := mat ginger_dark.assets 0.35 0.85 0.35 in
    let white : MaterialAdded := mat green.assets 0.97 0.97 0.97 in
    let dark : MaterialAdded := mat white.assets 0.14 0.15 0.2 in
    let spark : MaterialAdded := mat dark.assets 1.0 0.92 0.35 in
    let flag_off : MaterialAdded := mat spark.assets 0.85 0.25 0.25 in
    let flag_on : MaterialAdded := mat flag_off.assets 0.25 0.9 0.4 in
    let beacon : MaterialAdded := assets_add_material flag_on.assets (material_unlit (color_rgb 0.45 0.95 1.0)) in
    let sun : MaterialAdded := assets_add_material beacon.assets (material_unlit (color_rgb 1.0 0.96 0.78)) in
    { assets := sun.assets,
      looks := { cube := cube.handle, sphere := sphere.handle, cylinder := cyl.handle,
                 grass := grass.handle, stone := stone.handle, wood := wood.handle, gold := gold.handle,
                 pink := pink.handle, snout := snout.handle, ginger := ginger.handle,
                 ginger_dark := ginger_dark.handle, green := green.handle, white := white.handle, dark := dark.handle,
                 spark := spark.handle, flag_off := flag_off.handle, flag_on := flag_on.handle,
                 beacon := beacon.handle, sun := sun.handle : Looks }
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

/// A part turned by `r` (ears, a tail).
def turned_part (w : World) (parent : Entity) (p : Vec3) (r : Quat) (s : Vec3) (m : MeshHandle)
    (mt : MaterialHandle) : World :=
    let e : Spawned := spawn_transform_child w (transform_new p r s) parent in
    set_mesh e.world e.entity (mesh_component m mt)

/// A part with a `Name`, for animations and tweens to find.
def named_part (w : World) (parent : Entity) (name : String) (p : Vec3) (s : Vec3) (m : MeshHandle)
    (mt : MaterialHandle) : World :=
    let e : Spawned := spawn_transform_child w (transform_new p quat_identity s) parent in
    set_name (set_mesh e.world e.entity (mesh_component m mt)) e.entity name

def plat_material (lk : Looks) (k : I64) : MaterialHandle :=
    if k == kind_stone then lk.stone
    else if k == kind_wood then lk.wood
    else if k == kind_gold then lk.gold
    else if k == kind_climb then lk.green
    else lk.grass

/// Rest at the centre, travel to `to`, rest there; played ping-pong, so
/// each end rests `2 * mover_dwell` s.
def mover_clip (p : Plat) : Clip :=
    clip_timed (mover_dwell + mover_travel + mover_dwell)
        [channel "" (track Property.prop_translation
            [key_vec3 0.0 p.center Easing.linear, key_vec3 mover_dwell p.center Easing.linear,
             key_vec3 (mover_dwell + mover_travel) p.to Easing.sine_in_out])]
        []

def spawn_plat (lk : Looks) (w : World) (p : Plat) : World :=
    let e : Spawned := shown w p.center quat_identity (v3_scale p.half 2.0) lk.cube (plat_material lk p.kind) in
    let w1 : World :=
        if p.kind == kind_climb
        then set_collider e.world e.entity
                 (collider_with_layers (collider (shape_box p.half)) (layer_world + layer_climb) layer_all)
        else set_collider e.world e.entity (collider (shape_box p.half)) in
    if p.moves
    then insert_component (set_animator w1 e.entity (animator (mover_clip p) LoopMode.loop_ping_pong))
             e.entity carrier_name (Any.any (carrier_at p.center))
    else w1

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
    let flag0 : Spawned := shown pole.world (v3_add p (vec3 2.15 1.75 0.0)) quat_identity (vec3 0.6 0.4 0.05)
                                 lk.cube lk.flag_off in
    let flag : Spawned := { world := set_animator flag0.world flag0.entity (animator_at (animator flag_wave LoopMode.loop_ping_pong) (f64_of_i64 index * 0.37)),
                            entity := flag0.entity : Spawned } in
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

/// A flag swinging a little about its pole (y), there and back.
def flag_wave : Clip :=
    clip [channel "" (track Property.prop_rotation
            [key_quat 0.0 (quat_from_axis_angle (vec3 0.0 1.0 0.0) (0.0 - 0.3)) Easing.linear,
             key_quat 0.8 (quat_from_axis_angle (vec3 0.0 1.0 0.0) 0.3) Easing.sine_in_out])]
         []

/// The gem bobs between 2.0 and 2.35 above the pad.
def gem_bob (p : Vec3) : Clip :=
    clip [channel "" (track Property.prop_translation
            [key_vec3 0.0 (v3_add p (vec3 0.0 2.0 0.0)) Easing.linear,
             key_vec3 0.9 (v3_add p (vec3 0.0 2.35 0.0)) Easing.sine_in_out])]
         []

/// The goal at platform-top point `p`: a glowing pad, a gold cube spinning
/// and bobbing above it, and a trigger around both.
def spawn_goal (lk : Looks) (w : World) (p : Vec3) : World :=
    let pad : Spawned := shown w (v3_add p (vec3 0.0 0.05 0.0)) quat_identity (vec3 2.2 0.1 2.2) lk.cylinder lk.beacon in
    let gem : Spawned := shown pad.world (v3_add p (vec3 0.0 2.0 0.0)) spark_tilt (vec3 0.7 0.7 0.7) lk.cube lk.gold in
    let w0 : World := set_animator gem.world gem.entity (animator (gem_bob p) LoopMode.loop_ping_pong) in
    let w1 : World := insert_component w0 gem.entity spin_name (Any.any { speed := 1.5, tilt := spark_tilt : Spin }) in
    let trig : Spawned := spawn_transform w1 (transform_new (v3_add p (vec3 0.0 1.5 0.0)) quat_identity (vec3 1.0 1.0 1.0)) in
    let w2 : World := set_collider trig.world trig.entity (collider_trigger (shape_box (vec3 1.2 1.5 1.2))) in
    insert_component w2 trig.entity goal_name (Any.any { reached := false : Goal })

// ── Mo: Xiaozhu (a piggy) or Xiaomao (a kitty) ──────────────────────
//
// Hero identity and ability constants are in `hero.mo`.

def x_axis : Vec3 := vec3 1.0 0.0 0.0

def z_axis : Vec3 := vec3 0.0 0.0 1.0

/// Xiaozhu: a round pink body, a flat snout with nostrils, dark eyes,
/// floppy ears tipped forward, hooves and a curly tail. Parts are children
/// of Mo's root, in Mo's frame (+z is the front; the body is centred 0.12
/// below the root).
def dress_xiaozhu (lk : Looks) (w : World) (e : Entity) : World :=
    let w1 : World := named_part w e body_name (vec3 0.0 (0.0 - 0.12) 0.0) (vec3 1.0 0.95 1.0) lk.sphere lk.pink in
    let w2 : World := part w1 e (vec3 0.0 (0.0 - 0.1) 0.46) (vec3 0.34 0.24 0.16) lk.sphere lk.snout in
    let w3 : World := part w2 e (vec3 0.06 (0.0 - 0.1) 0.54) (vec3 0.05 0.08 0.02) lk.cube lk.dark in
    let w4 : World := part w3 e (vec3 (0.0 - 0.06) (0.0 - 0.1) 0.54) (vec3 0.05 0.08 0.02) lk.cube lk.dark in
    let w5 : World := part w4 e (vec3 0.15 0.1 0.42) (vec3 0.09 0.11 0.06) lk.sphere lk.dark in
    let w6 : World := part w5 e (vec3 (0.0 - 0.15) 0.1 0.42) (vec3 0.09 0.11 0.06) lk.sphere lk.dark in
    let ear : Quat := quat_from_axis_angle x_axis 0.5 in
    let w7 : World := turned_part w6 e (vec3 0.22 0.36 0.12) (quat_mul (quat_from_axis_angle z_axis (0.0 - 0.35)) ear) (vec3 0.2 0.22 0.06) lk.cube lk.snout in
    let w8 : World := turned_part w7 e (vec3 (0.0 - 0.22) 0.36 0.12) (quat_mul (quat_from_axis_angle z_axis 0.35) ear) (vec3 0.2 0.22 0.06) lk.cube lk.snout in
    let w9 : World := part w8 e (vec3 0.2 (0.0 - 0.62) 0.06) (vec3 0.22 0.14 0.3) lk.cube lk.snout in
    let w10 : World := part w9 e (vec3 (0.0 - 0.2) (0.0 - 0.62) 0.06) (vec3 0.22 0.14 0.3) lk.cube lk.snout in
    let w11 : World := part w10 e (vec3 0.0 0.0 (0.0 - 0.52)) (vec3 0.12 0.12 0.12) lk.sphere lk.snout in
    part w11 e (vec3 0.05 0.09 (0.0 - 0.56)) (vec3 0.08 0.08 0.08) lk.sphere lk.snout

/// Xiaomao: a ginger body with a white muzzle and paws, green eyes, a pink
/// nose, whiskers, pointed ears (cubes turned 45 degrees, half sunk into the
/// head) and a tail held up behind.
def dress_xiaomao (lk : Looks) (w : World) (e : Entity) : World :=
    let w1 : World := named_part w e body_name (vec3 0.0 (0.0 - 0.12) 0.0) (vec3 0.95 1.0 0.95) lk.sphere lk.ginger in
    let w2 : World := part w1 e (vec3 0.0 (0.0 - 0.14) 0.4) (vec3 0.36 0.24 0.2) lk.sphere lk.white in
    let w3 : World := part w2 e (vec3 0.0 (0.0 - 0.05) 0.5) (vec3 0.08 0.06 0.05) lk.sphere lk.pink in
    let w4 : World := part w3 e (vec3 0.15 0.1 0.41) (vec3 0.11 0.15 0.06) lk.sphere lk.green in
    let w5 : World := part w4 e (vec3 (0.0 - 0.15) 0.1 0.41) (vec3 0.11 0.15 0.06) lk.sphere lk.green in
    let w6 : World := part w5 e (vec3 0.15 0.1 0.44) (vec3 0.03 0.11 0.02) lk.cube lk.dark in
    let w7 : World := part w6 e (vec3 (0.0 - 0.15) 0.1 0.44) (vec3 0.03 0.11 0.02) lk.cube lk.dark in
    let w8 : World := part w7 e (vec3 0.24 (0.0 - 0.1) 0.44) (vec3 0.26 0.015 0.015) lk.cube lk.white in
    let w9 : World := part w8 e (vec3 (0.0 - 0.24) (0.0 - 0.1) 0.44) (vec3 0.26 0.015 0.015) lk.cube lk.white in
    let ear : Quat := quat_from_axis_angle z_axis 0.785 in
    let w10 : World := turned_part w9 e (vec3 0.22 0.36 0.05) (quat_mul (quat_from_axis_angle z_axis (0.0 - 0.3)) ear) (vec3 0.2 0.2 0.08) lk.cube lk.ginger_dark in
    let w11 : World := turned_part w10 e (vec3 (0.0 - 0.22) 0.36 0.05) (quat_mul (quat_from_axis_angle z_axis 0.3) ear) (vec3 0.2 0.2 0.08) lk.cube lk.ginger_dark in
    let w12 : World := part w11 e (vec3 0.2 (0.0 - 0.62) 0.06) (vec3 0.22 0.14 0.3) lk.cube lk.white in
    let w13 : World := part w12 e (vec3 (0.0 - 0.2) (0.0 - 0.62) 0.06) (vec3 0.22 0.14 0.3) lk.cube lk.white in
    let w14 : World := turned_part w13 e (vec3 0.0 0.05 (0.0 - 0.62)) (quat_from_axis_angle x_axis (0.0 - 0.55)) (vec3 0.09 0.65 0.09) lk.cylinder lk.ginger in
    part w14 e (vec3 0.0 0.36 (0.0 - 0.8)) (vec3 0.11 0.11 0.11) lk.sphere lk.ginger_dark

/// Hero `h`'s parts on Mo's root `e`.
pub def dress_mo (lk : Looks) (h : I64) (w : World) (e : Entity) : World :=
    if h == hero_xiaomao then dress_xiaomao lk w e else dress_xiaozhu lk w e

/// Mo `e` re-dressed as hero `h`, in place: the old parts go, the new ones
/// are added. The root (capsule, state, position) is untouched, so a switch
/// mid-level keeps the run.
pub def redress_mo (lk : Looks) (h : I64) (w : World) (e : Entity) : World :=
    dress_mo lk h (despawn_all w (children_of w e)) e

/// Mo as hero `h` at ground point `p`, facing -z. The root carries the
/// capsule and the state; the look is children (`dress_mo`).
pub def spawn_mo_as (lk : Looks) (h : I64) (w : World) (p : Vec3) : Spawned :=
    let face : Vec3 := vec3 0.0 0.0 (0.0 - 1.0) in
    let root : Spawned := spawn_transform w (transform_new (v3_add p (vec3 0.0 (mo_stand + 0.01) 0.0)) (yaw_quat face) (vec3 1.0 1.0 1.0)) in
    let e : Entity := root.entity in
    let w1 : World := set_mo (set_collider root.world e (mo_move_layers mo_shape)) e (mo_rest_for h) in
    { world := dress_mo lk h w1 e, entity := e : Spawned }

/// Xiaozhu Mo at `p`.
pub def spawn_mo (lk : Looks) (w : World) (p : Vec3) : Spawned := spawn_mo_as lk hero_xiaozhu w p

// ── Puzzle props ────────────────────────────────────────────────────

/// A breakable box (Xiaozhu's slam). Marker component, `Copy`.
pub def box_name : String := "mo.box"

/// A spin-trip switch (Xiaomao). Carries a `Switch`.
pub def switch_name : String := "mo.switch"

/// A gate a switch opens. Carries a `Gate`.
pub def gate_name : String := "mo.gate"

/// A box's half extents: 1.4 wide, 2.4 tall, 1.2 deep -- too tall to jump.
pub def box_half : Vec3 := vec3 0.7 1.2 0.6

/// A crate at ground point `p`: a wooden cube with a solid collider.
def spawn_box (lk : Looks) (w : World) (p : Vec3) : World :=
    let centre : Vec3 := v3_add p (vec3 0.0 box_half.y 0.0) in
    let e : Spawned := shown w centre quat_identity (v3_scale box_half 2.0) lk.cube lk.wood in
    insert_component (set_collider e.world e.entity (collider (shape_box box_half))) e.entity box_name (Any.any true)

#[terminating]
def spawn_boxes (lk : Looks) (w : World) (ps : List Vec3) : World :=
    match ps {
        List.empty => w,
        List.cons p rest => spawn_boxes lk (spawn_box lk w p) rest
    }

/// A switch at ground point `p`: a small pad with a glowing orb, and a
/// trigger the spin reaches.
def spawn_switch (lk : Looks) (w : World) (sw : Switch) : World :=
    let p : Vec3 := switch_pos sw in
    let pad : Spawned := shown w (v3_add p (vec3 0.0 0.1 0.0)) quat_identity (vec3 1.0 0.2 1.0) lk.cylinder lk.stone in
    let orb : Spawned := shown pad.world (v3_add p (vec3 0.0 0.75 0.0)) quat_identity (vec3 0.45 0.45 0.45) lk.sphere lk.beacon in
    let trig : Spawned := spawn_transform orb.world (transform_new (v3_add p (vec3 0.0 0.9 0.0)) quat_identity (vec3 1.0 1.0 1.0)) in
    let w1 : World := set_collider trig.world trig.entity (collider_trigger (shape_sphere 1.0)) in
    insert_component w1 trig.entity switch_name (Any.any sw)

#[terminating]
def spawn_switches (lk : Looks) (w : World) (sws : List Switch) : World :=
    match sws {
        List.empty => w,
        List.cons sw rest => spawn_switches lk (spawn_switch lk w sw) rest
    }

/// A gate: a tall bar with a solid collider, tagged with its switch id.
def spawn_gate (lk : Looks) (w : World) (g : Gate) : World :=
    let e : Spawned := shown w (gate_pos g) quat_identity (v3_scale (gate_half g) 2.0) lk.cube lk.stone in
    let w1 : World := set_collider e.world e.entity (collider (shape_box (gate_half g))) in
    insert_component w1 e.entity gate_name (Any.any g)

#[terminating]
def spawn_gates (lk : Looks) (w : World) (gs : List Gate) : World :=
    match gs {
        List.empty => w,
        List.cons g rest => spawn_gates lk (spawn_gate lk w g) rest
    }

/// The sun's disc, tagged so `game.mo` can keep it out along the light.
pub def sun_name : String := "mo.sun"

def spawn_sun (lk : Looks) (w : World) : World :=
    let s : Spawned := shown w (vec3 0.0 60.0 (0.0 - 40.0)) quat_identity (vec3 7.0 7.0 7.0) lk.sphere lk.sun in
    insert_component s.world s.entity sun_name (Any.any true)

/// A whole level spawned into `w`, with Mo (as hero `h`) at the start.
pub def spawn_level_as (lk : Looks) (h : I64) (w : World) (lv : Level) : World :=
    let w1 : World := spawn_plats lk w lv.plats in
    let w2 : World := spawn_plats lk w1 lv.climbs in
    let w3 : World := spawn_boxes lk w2 lv.boxes in
    let w4 : World := spawn_switches lk w3 lv.switches in
    let w5 : World := spawn_gates lk w4 lv.gates in
    let w6 : World := spawn_sparks lk w5 lv.sparks in
    let w7 : World := spawn_posts lk w6 lv.posts 1 in
    let w8 : World := spawn_goal lk w7 lv.goal in
    let w9 : World := spawn_sun lk w8 in
    let player : Spawned := spawn_mo_as lk h w9 lv.start in
    let wp : World := insert_component player.world player.entity player_name (Any.any true) in
    let beside : Vec3 := v3_add lv.start (vec3 0.0 0.0 1.2) in
    let friend : Spawned := spawn_mo_as lk (hero_next h) wp beside in
    insert_component friend.world friend.entity companion_name (Any.any true)

/// `spawn_level_as` with Xiaozhu.
pub def spawn_level (lk : Looks) (w : World) (lv : Level) : World := spawn_level_as lk hero_xiaozhu w lv

/// A whole level in a fresh world, with Mo at the start.
pub def level_world (lk : Looks) (lv : Level) : World := spawn_level lk empty_world lv

#[terminating]
def despawn_all (w : World) (es : List Entity) : World :=
    match es {
        List.empty => w,
        List.cons e rest => despawn_all (despawn w e) rest
    }

/// Every level entity gone (they all have transforms; resources do not).
pub def clear_level (w : World) : World := despawn_all w (query_entities w [transform_name] [])
