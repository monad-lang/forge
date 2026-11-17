// forge-app on the web: the demo bin. Phase 9a, see ../../../PLAN.md.
//
// A spinning meshed hierarchy over a textured floor, drawn by forge-webgl
// and driven by `forge_app::web`. It is also the template for a web game:
// the only modules it names are `forge_app` and `forge_app::web` (plus the
// engine vocabulary motes for meshes and transforms), and it holds the three
// export thunks the web loader calls.
//
//   root cube (spins about y)  at the origin
//    └ cylinder               2 units out on +x, so it ORBITS the root
//       └ small cube          on top of the cylinder
//   floor quad                1.5 below, textured `forge-floor.png` if served
//
// WASD or the arrow keys slide the whole hierarchy across the floor,
// relative to the camera (hold Shift to go faster): a system reading
// `world_input`. The camera is an orbit camera (`forge_app::orbit`):
// right- or middle-drag or Q/E/R/F rotate, the wheel zooms. Clicking a mesh
// records its entity id in the canvas's `data-picked`.
//
// Run it in a browser: `devenv shell -- scripts/web-serve.sh`, then open
// http://localhost:8080 (README.md, "Run the demo in a browser").

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, empty_world, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math {Vec3, vec3, v3_add, v3_scale, Quat, quat_from_axis_angle, f64_half_pi}
use forge_scene {
    Transform, transform_new, transform_from_translation, transform_name,
    spawn_transform, spawn_transform_child, entity_transform
}
use forge_schedule {update_s, world_time, time_elapsed, time_delta}
use forge_render {
    color, color_rgb, Assets, assets_empty, MeshAdded, MaterialAdded, TextureAdded,
    assets_add_mesh, assets_add_material, assets_add_texture, mesh_cube, mesh_box,
    mesh_cylinder, mesh_quad, material_flat, material_textured, texture_from_url,
    mesh_component, set_mesh, MeshHandle, MaterialHandle
}
use lib::app {
    App, app_new, app_add_system, app_set_assets, app_set_initial_world,
    app_set_clear_color, CameraRig, camera_rig
}
use lib::input {Input, world_input, input_axis, input_key_held}
use lib::orbit {
    Orbit, orbit_new, orbit_rig, orbit_forward, orbit_right, world_orbit_opt, app_add_orbit_camera
}
use lib::web {web_mount, web_dispatch, web_tick}

// ── Spin ────────────────────────────────────────────────────────────

/// Radians per second about +y. `Copy`.
#[derive Copy Clone]
struct Spin {
    speed : F64
}

def spin_name : String := "demo.spin"

def as_spin (v : Any) : Spin :=
    match v { Any.any x => let s : Spin := x in s }

def spin_of (world : World) (e : Entity) : F64 :=
    match get_component_named world e spin_name {
        Option.some v => (as_spin v).speed,
        Option.none => 0.0
    }

/// Set `e`'s rotation to `angle` about +y, keeping translation and scale.
def spin_to (world : World) (e : Entity) (angle : F64) : World :=
    match entity_transform world e {
        Option.none => world,
        Option.some t0 =>
            let t : Transform := t0 in
            let q : Quat := quat_from_axis_angle (vec3 0.0 1.0 0.0) angle in
            insert_component world e transform_name (Any.any (transform_new t.translation q t.scale))
    }

#[terminating]
def spin_go (world : World) (elapsed : F64) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest =>
            spin_go (spin_to world e (elapsed * spin_of world e)) elapsed rest
    }

/// The rotation is a function of the clock, not an accumulation, so it does
/// not drift with frame rate.
def spin_all (world : World) : World :=
    spin_go world (time_elapsed (world_time world)) (query_entities world [spin_name, transform_name] [])

def spin_system : WorldM Id Unit := WorldM.modify spin_all

// ── Move ────────────────────────────────────────────────────────────

/// Tags the entity the keyboard drives. `Copy`.
#[derive Copy Clone]
struct Player {
    speed : F64
}

def player_name : String := "demo.player"

/// Either key of a pair: WASD and the arrows both work.
def axis2 (i : Input) (neg : String) (pos : String) (neg2 : String) (pos2 : String) : F64 :=
    let a : F64 := input_axis i neg pos + input_axis i neg2 pos2 in
    if a > 1.0 then 1.0 else if a < 0.0 - 1.0 then 0.0 - 1.0 else a

/// This frame's move in world units, relative to the camera: A/D along its
/// right, W/S along its facing (both on the ground plane).
def step_of (o : Orbit) (i : Input) (dt : F64) : Vec3 :=
    let fast : Bool := input_key_held i "ShiftLeft" || input_key_held i "ShiftRight" in
    let speed : F64 := if fast then 6.0 else 2.5 in
    v3_scale (v3_add (v3_scale (orbit_right o) (axis2 i "KeyA" "KeyD" "ArrowLeft" "ArrowRight"))
                     (v3_scale (orbit_forward o) (axis2 i "KeyS" "KeyW" "ArrowDown" "ArrowUp")))
             (speed * dt)

def view_orbit (world : World) : Orbit :=
    match world_orbit_opt world {
        Option.some o => o,
        Option.none => start_orbit
    }

def move_by (world : World) (e : Entity) (step : Vec3) : World :=
    match entity_transform world e {
        Option.none => world,
        Option.some t0 =>
            let t : Transform := t0 in
            insert_component world e transform_name
                (Any.any (transform_new (v3_add t.translation step) t.rotation t.scale))
    }

#[terminating]
def move_go (world : World) (step : Vec3) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest => move_go (move_by world e step) step rest
    }

def move_all (world : World) : World :=
    move_go world (step_of (view_orbit world) (world_input world) (time_delta (world_time world)))
        (query_entities world [player_name, transform_name] [])

def move_system : WorldM Id Unit := WorldM.modify move_all

// ── Assets ──────────────────────────────────────────────────────────

/// Handles the scene builder needs. `Copy`.
#[derive Copy Clone]
struct Handles {
    cube : MeshHandle,
    small : MeshHandle,
    cylinder : MeshHandle,
    floor : MeshHandle,
    red : MaterialHandle,
    teal : MaterialHandle,
    gold : MaterialHandle,
    ground : MaterialHandle
}

/// The asset tables and the handles into them.
struct Loaded {
    assets : Assets,
    handles : Handles
}

instance Copy Loaded {
    def copy (l : Loaded) : Pair Loaded Loaded := Pair.pair l l
}

def load : Loaded :=
    let cube : MeshAdded := assets_add_mesh assets_empty (mesh_cube 0.75) in
    let small : MeshAdded := assets_add_mesh cube.assets (mesh_box 0.3 0.3 0.3) in
    let cyl : MeshAdded := assets_add_mesh small.assets (mesh_cylinder 0.4 1.0 24) in
    let floor : MeshAdded := assets_add_mesh cyl.assets (mesh_quad 10.0 10.0) in
    let tex : TextureAdded := assets_add_texture floor.assets (texture_from_url "forge-floor.png") in
    let red : MaterialAdded := assets_add_material tex.assets (material_flat (color_rgb 0.85 0.25 0.2)) in
    let teal : MaterialAdded := assets_add_material red.assets (material_flat (color_rgb 0.15 0.65 0.65)) in
    let gold : MaterialAdded := assets_add_material teal.assets (material_flat (color_rgb 0.95 0.75 0.2)) in
    let ground : MaterialAdded :=
        assets_add_material gold.assets (material_textured tex.handle (color 0.6 0.6 0.65 1.0)) in
    { assets := ground.assets,
      handles := { cube := cube.handle, small := small.handle, cylinder := cyl.handle,
                   floor := floor.handle, red := red.handle, teal := teal.handle,
                   gold := gold.handle, ground := ground.handle : Handles }
      : Loaded }

// ── Scene ───────────────────────────────────────────────────────────

def with_spin (world : World) (e : Entity) (speed : F64) : World :=
    let s : Spin := { speed := speed : Spin } in
    insert_component world e spin_name (Any.any s)

def as_player (world : World) (e : Entity) : World :=
    let p : Player := { speed := 1.0 : Player } in
    insert_component world e player_name (Any.any p)

def scene (h : Handles) : World :=
    let root : Spawned := spawn_transform empty_world (transform_from_translation (vec3 0.0 0.0 0.0)) in
    let w0 : World := as_player root.world root.entity in
    let w1 : World := with_spin (set_mesh w0 root.entity (mesh_component h.cube h.red)) root.entity 0.8 in
    let arm : Spawned := spawn_transform_child w1 (transform_from_translation (vec3 2.0 0.0 0.0)) root.entity in
    let w2 : World := set_mesh arm.world arm.entity (mesh_component h.cylinder h.teal) in
    let top : Spawned := spawn_transform_child w2 (transform_from_translation (vec3 0.0 0.8 0.0)) arm.entity in
    let w3 : World := with_spin (set_mesh top.world top.entity (mesh_component h.small h.gold)) top.entity 3.0 in
    let tilt : Quat := quat_from_axis_angle (vec3 1.0 0.0 0.0) (0.0 - f64_half_pi) in
    let floor : Spawned :=
        spawn_transform w3 (transform_new (vec3 0.0 (0.0 - 1.5) 0.0) tilt (vec3 1.0 1.0 1.0)) in
    set_mesh floor.world floor.entity (mesh_component h.floor h.ground)

// ── The app ─────────────────────────────────────────────────────────

def demo : App :=
    let l : Loaded := load in
    app_set_clear_color
        (app_set_initial_world
            (app_set_assets
                (app_add_orbit_camera
                    (app_add_system (app_add_system app_new "spin" update_s spin_system)
                        "move" update_s move_system)
                    start_orbit)
                l.assets)
            (scene l.handles))
        (color 0.08 0.09 0.12 1.0)

/// Where the camera starts: about (4, 3.5, 7) looking at (0.5, 0, 0).
def start_orbit : Orbit := orbit_new (vec3 0.5 0.0 0.0) 0.4636 0.4205 8.573 0.9

def rig : CameraRig := orbit_rig start_orbit

#[export "c"]
def oak_mount : IO Unit := web_mount demo rig

#[export "c"]
def oak_dispatch_event (handler : I64) : IO Unit := web_dispatch handler

#[export "c"]
def oak_tick : IO Unit := web_tick

def main : IO Unit := IO.pure unit
