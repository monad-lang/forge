// forge-render: the sun. One directional light per world, stored as a
// resource (a singleton entity, the same pattern forge-schedule uses for
// `Time`).
//
// `extract` emits a `set_light` command when the world has a light, and
// `frame_plan` puts it on the `FramePlan`. A world without one is drawn under
// `light_default`, the fixed sun the shaders used to hard-code (ambient 0.5
// plus 0.5 diffuse from up and to the side), so older apps look the same.
//
// The shadow box is decided here, natively tested, not in a backend:
// `light_view_projection` is an orthographic box `2 * extent` wide and
// `depth` long, looking along the light at `focus` (the app moves it with
// the action, e.g. the player). The focus is snapped to whole shadow-map
// texels across the light's view, so a moving focus slides the box in
// texel steps and shadow edges don't shimmer.

use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {World, Spawned, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_math::{
    Vec3, vec3, v3_zero, v3_add, v3_scale, v3_normalize, v3_dot, v3_cross, v3_neg,
    Mat4, mat4_mul, mat4_look_at, mat4_orthographic, mat4_transform_point, f64_abs, f64_floor, f64_of_i64
}
use forge_core::ecs {empty_world}

/// A directional light. `toward` is a unit vector from the scene TOWARD the
/// sun. `color` is linear RGB, scaled by `intensity` for the diffuse term;
/// `ambient` is added on every surface. `shadows` asks a backend for a
/// shadow map of `map_size`^2 texels covering the box around `focus`.
/// `Copy`.
#[derive Copy Clone Debug]
pub struct Light {
    toward : Vec3,
    color : Vec3,
    intensity : F64,
    ambient : F64,
    shadows : Bool,
    focus : Vec3,
    extent : F64,
    depth : F64,
    map_size : I64
}

/// A sun shining from `toward` (normalized here), with no shadows.
pub def light_sun (toward : Vec3) (color : Vec3) (intensity : F64) (ambient : F64) : Light :=
    { toward := v3_normalize toward, color := color, intensity := intensity, ambient := ambient,
      shadows := false, focus := v3_zero, extent := 20.0, depth := 80.0, map_size := 2048
      : Light }

/// The light a world without one is drawn under: white, ambient 0.5, diffuse
/// 0.5 from (0.35, 0.85, 0.4). This matches what the shaders hard-coded before
/// lights existed.
pub def light_default : Light := light_sun (vec3 0.35 0.85 0.4) (vec3 1.0 1.0 1.0) 0.5 0.5

/// `l` casting shadows over a box `2 * extent` wide and `depth` long, into
/// a `map_size`^2 shadow map.
pub def light_with_shadows (l : Light) (extent : F64) (depth : F64) (map_size : I64) : Light :=
    { l with shadows := true, extent := extent, depth := depth, map_size := map_size }

/// `l` with its shadow box centred on `p`.
pub def light_at (l : Light) (p : Vec3) : Light := { l with focus := p }

pub def light_toward (l : Light) : Vec3 := l.toward

pub def light_color (l : Light) : Vec3 := l.color

pub def light_intensity (l : Light) : F64 := l.intensity

pub def light_ambient (l : Light) : F64 := l.ambient

pub def light_shadows (l : Light) : Bool := l.shadows

pub def light_focus (l : Light) : Vec3 := l.focus

pub def light_extent (l : Light) : F64 := l.extent

pub def light_depth (l : Light) : F64 := l.depth

pub def light_map_size (l : Light) : I64 := l.map_size

/// The diffuse colour a shader multiplies by `max(n . toward, 0)`.
pub def light_diffuse (l : Light) : Vec3 := v3_scale l.color l.intensity

// ── Shadow box ──────────────────────────────────────────────────────

/// An up vector that is not parallel to the light.
def up_for (toward : Vec3) : Vec3 :=
    if f64_abs toward.y > 0.99 then vec3 0.0 0.0 1.0 else vec3 0.0 1.0 0.0

/// The size of one shadow-map texel, in world units.
pub def light_texel (l : Light) : F64 := 2.0 * l.extent / f64_of_i64 l.map_size

/// `x` moved down to a whole multiple of `step`, as an offset.
def snap_offset (x : F64) (step : F64) : F64 := f64_floor (x / step) * step - x

/// The focus, snapped to whole texels across the light's view (along the
/// view's right and up axes; depth needs no snapping).
pub def light_snapped_focus (l : Light) : Vec3 :=
    let f : Vec3 := v3_neg l.toward in
    let s : Vec3 := v3_normalize (v3_cross f (up_for l.toward)) in
    let u : Vec3 := v3_cross s f in
    let t : F64 := light_texel l in
    v3_add l.focus (v3_add (v3_scale s (snap_offset (v3_dot l.focus s) t))
                           (v3_scale u (snap_offset (v3_dot l.focus u) t)))

/// The light's view: from `depth / 2` toward the sun, looking at the
/// (snapped) focus.
pub def light_view (l : Light) : Mat4 :=
    let c : Vec3 := light_snapped_focus l in
    mat4_look_at (v3_add c (v3_scale l.toward (l.depth * 0.5))) c (up_for l.toward)

/// The shadow box: `[-extent, extent]^2` across, `depth` along the light.
pub def light_projection (l : Light) : Mat4 :=
    mat4_orthographic (0.0 - l.extent) l.extent (0.0 - l.extent) l.extent 0.0 l.depth

/// World -> the shadow map's clip space.
pub def light_view_projection (l : Light) : Mat4 := mat4_mul (light_projection l) (light_view l)

// ── Resource ────────────────────────────────────────────────────────

pub def light_name : String := "forge.light"

def as_light (v : Any) : Light :=
    match v { Any.any x => let l : Light := x in l }

/// The world's light, if it set one.
pub def world_light_opt (world : World) : Option Light :=
    match List.first (query_entities world [light_name] []) {
        Option.some e =>
            match get_component_named world e light_name {
                Option.some v => Option.some (as_light v),
                Option.none => Option.none
            },
        Option.none => Option.none
    }

/// The world's light, else `light_default`.
pub def world_light (world : World) : Light :=
    match world_light_opt world {
        Option.some l => l,
        Option.none => light_default
    }

pub def world_set_light (world : World) (l : Light) : World :=
    match List.first (query_entities world [light_name] []) {
        Option.some e => insert_component world e light_name (Any.any l),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair light_name (Any.any l)] in
            s.world
    }

// ── Tests ───────────────────────────────────────────────────────────

def close (e : F64) (a : F64) (b : F64) : Bool := f64_abs (a - b) < e

#[test]
def test_default_light_points_up_and_to_the_side : Bool :=
    let t : Vec3 := light_toward light_default in
    close 0.000001 (v3_dot t t) 1.0 && t.y > 0.8 && close 0.000001 (light_ambient light_default) 0.5

/// The focus lands in the middle of the shadow map (within a texel).
#[test]
def test_focus_projects_to_the_map_centre : Bool :=
    let l : Light := light_at (light_with_shadows light_default 10.0 40.0 1024) (vec3 3.3 1.7 (0.0 - 8.2)) in
    let p : Vec3 := mat4_transform_point (light_view_projection l) (light_focus l) in
    let texel_ndc : F64 := 2.0 / 1024.0 in
    f64_abs p.x <= texel_ndc * 1.5 && f64_abs p.y <= texel_ndc * 1.5 && p.z > (0.0 - 1.0) && p.z < 1.0

/// A point toward the sun is nearer the light (smaller depth) than one away.
#[test]
def test_toward_the_sun_is_nearer : Bool :=
    let l : Light := light_with_shadows light_default 10.0 40.0 1024 in
    let m : Mat4 := light_view_projection l in
    let a : Vec3 := mat4_transform_point m (v3_scale (light_toward l) 5.0) in
    let b : Vec3 := mat4_transform_point m (v3_scale (light_toward l) (0.0 - 5.0)) in
    a.z < b.z

/// Two focuses inside one texel cell give the same box (no shimmer).
#[test]
def test_focus_snaps_to_texels : Bool :=
    // Straight down: the view's right axis is -x, so x = -0.25 and -0.75
    // texels are 0.25 and 0.75 texels along it, inside the same cell.
    let base : Light := light_with_shadows (light_sun (vec3 0.0 1.0 0.0) (vec3 1.0 1.0 1.0) 0.5 0.5) 20.0 40.0 2048 in
    let t : F64 := light_texel base in
    let a : Vec3 := light_snapped_focus (light_at base (vec3 (0.0 - 0.25 * t) 0.0 0.0)) in
    let b : Vec3 := light_snapped_focus (light_at base (vec3 (0.0 - 0.75 * t) 0.0 0.0)) in
    let c : Vec3 := light_snapped_focus (light_at base (vec3 (0.0 - 1.25 * t) 0.0 0.0)) in
    a.x == b.x && a.z == b.z && Bool.not (a.x == c.x)

#[test]
def test_world_light_resource : Bool :=
    let none : Bool := match world_light_opt empty_world { Option.some _ => false, Option.none => true } in
    let w : World := world_set_light empty_world (light_sun (vec3 0.0 1.0 0.0) (vec3 1.0 0.5 0.25) 0.8 0.3) in
    let w2 : World := world_set_light w (light_at (world_light w) (vec3 1.0 2.0 3.0)) in
    let l : Light := world_light w2 in
    let f : Vec3 := light_focus l in
    let c : Vec3 := light_color l in
    none && f.z == 3.0 && c.y == 0.5 && close 0.000001 (light_intensity l) 0.8
