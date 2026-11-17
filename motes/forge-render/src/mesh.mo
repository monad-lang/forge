// forge-render: mesh DATA. Phase 9a, see ../../../PLAN.md.
//
// A `MeshHandle` is a bare id; `MeshData` is what the id stands for: an
// interleaved vertex list and a triangle index list. It is PURE -- no buffer,
// no IO, no backend type -- so the same value feeds the WebGL backend (which
// packs it into a `Buf F32`/`Buf I32`), a test (which counts it), and picking
// (which reads its bounds).
//
// Layout, the one every backend relies on:
//   vertices : x y z u v, repeated   (`mesh_stride` = 5 floats per vertex)
//   indices  : three per triangle, COUNTER-CLOCKWISE seen from outside
//
// The builders (`mesh_quad`/`mesh_box`/`mesh_disc`/`mesh_cylinder`) are
// centred on the origin. There is no integer->float conversion in the
// toolchain, so a segment index becomes an angle through forge-math's
// `f64_of_i64`.

use std::derive {}
use std::list {}
use init::copy {Copy}
use forge_math::{Vec3, vec3, AABB, aabb, f64_sin, f64_cos, f64_tau, f64_of_i64, f64_min, f64_max}

/// Floats per vertex: position (3) + uv (2).
pub def mesh_stride : I64 := 5

/// Interleaved vertices plus triangle indices. `Copy` is the hand-written
/// identity: both fields are immutable lists, so a duplicate shares them.
pub struct MeshData {
    vertices : List F64,
    indices : List I64
}

pub instance Copy MeshData {
    def copy (m : MeshData) : Pair MeshData MeshData := Pair.pair m m
}

pub def mesh_data (vertices : List F64) (indices : List I64) : MeshData :=
    { vertices := vertices, indices := indices : MeshData }

pub def mesh_vertices (m : MeshData) : List F64 := m.vertices

pub def mesh_indices (m : MeshData) : List I64 := m.indices

pub def mesh_vertex_count (m : MeshData) : I64 := I64.div (List.length m.vertices) mesh_stride

pub def mesh_index_count (m : MeshData) : I64 := List.length m.indices

pub def mesh_triangle_count (m : MeshData) : I64 := I64.div (List.length m.indices) 3

#[terminating]
def indices_below (xs : List I64) (limit : I64) : Bool :=
    match xs {
        List.empty => true,
        List.cons i rest => I64.lt i limit && Bool.not (I64.lt i 0) && indices_below rest limit
    }

/// A mesh a backend can upload as-is: whole vertices, whole triangles, and no
/// index past the last vertex.
pub def mesh_is_valid (m : MeshData) : Bool :=
    I64.beq (I64.rem (List.length m.vertices) mesh_stride) 0
        && I64.beq (I64.rem (List.length m.indices) 3) 0
        && indices_below m.indices (mesh_vertex_count m)

// ── Bounds ──────────────────────────────────────────────────────────

/// Walk the interleaved list; `k` is the float's slot within its vertex.
#[terminating]
def bounds_go (xs : List F64) (k : I64)
    (x0 : F64) (y0 : F64) (z0 : F64) (x1 : F64) (y1 : F64) (z1 : F64) : AABB :=
    match xs {
        List.empty => aabb (vec3 x0 y0 z0) (vec3 x1 y1 z1),
        List.cons v rest =>
            let next : I64 := I64.rem (I64.add k 1) mesh_stride in
            if I64.beq k 0 then bounds_go rest next (f64_min x0 v) y0 z0 (f64_max x1 v) y1 z1
            else if I64.beq k 1 then bounds_go rest next x0 (f64_min y0 v) z0 x1 (f64_max y1 v) z1
            else if I64.beq k 2 then bounds_go rest next x0 y0 (f64_min z0 v) x1 y1 (f64_max z1 v)
            else bounds_go rest next x0 y0 z0 x1 y1 z1
    }

def bounds_big : F64 := 1000000000000.0

/// The local-space bounding box (a degenerate box at the origin when empty).
pub def mesh_bounds (m : MeshData) : AABB :=
    if I64.beq (List.length m.vertices) 0
    then aabb (vec3 0.0 0.0 0.0) (vec3 0.0 0.0 0.0)
    else bounds_go m.vertices 0 bounds_big bounds_big bounds_big
                   (0.0 - bounds_big) (0.0 - bounds_big) (0.0 - bounds_big)

// ── Builders ────────────────────────────────────────────────────────

def vertex (p : Vec3) (u : F64) (v : F64) : List F64 := [p.x, p.y, p.z, u, v]

/// Four corners, counter-clockwise from the outside, with the unit uv square.
def face (a : Vec3) (b : Vec3) (c : Vec3) (d : Vec3) : List F64 :=
    List.append (vertex a 0.0 0.0)
        (List.append (vertex b 1.0 0.0)
            (List.append (vertex c 1.0 1.0) (vertex d 0.0 1.0)))

/// Two triangles per quad, for `n` quads whose corners start at `base`.
#[terminating]
def quad_indices (base : I64) (n : I64) : List I64 :=
    if I64.lt 0 n
    then List.append
            [base, I64.add base 1, I64.add base 2, base, I64.add base 2, I64.add base 3]
            (quad_indices (I64.add base 4) (I64.sub n 1))
    else []

/// A `width` x `height` rectangle in the XY plane, facing +z.
pub def mesh_quad (width : F64) (height : F64) : MeshData :=
    let x : F64 := width * 0.5 in
    let y : F64 := height * 0.5 in
    mesh_data
        (face (vec3 (0.0 - x) (0.0 - y) 0.0) (vec3 x (0.0 - y) 0.0) (vec3 x y 0.0) (vec3 (0.0 - x) y 0.0))
        (quad_indices 0 1)

/// A box of the given HALF extents: six faces, four vertices each (so every
/// face has its own uv square).
pub def mesh_box (hx : F64) (hy : F64) (hz : F64) : MeshData :=
    let nx : F64 := 0.0 - hx in
    let ny : F64 := 0.0 - hy in
    let nz : F64 := 0.0 - hz in
    let front : List F64 := face (vec3 nx ny hz) (vec3 hx ny hz) (vec3 hx hy hz) (vec3 nx hy hz) in
    let back : List F64 := face (vec3 hx ny nz) (vec3 nx ny nz) (vec3 nx hy nz) (vec3 hx hy nz) in
    let right : List F64 := face (vec3 hx ny hz) (vec3 hx ny nz) (vec3 hx hy nz) (vec3 hx hy hz) in
    let left : List F64 := face (vec3 nx ny nz) (vec3 nx ny hz) (vec3 nx hy hz) (vec3 nx hy nz) in
    let top : List F64 := face (vec3 nx hy hz) (vec3 hx hy hz) (vec3 hx hy nz) (vec3 nx hy nz) in
    let bottom : List F64 := face (vec3 nx ny nz) (vec3 hx ny nz) (vec3 hx ny hz) (vec3 nx ny hz) in
    mesh_data
        (List.append front
            (List.append back (List.append right (List.append left (List.append top bottom)))))
        (quad_indices 0 6)

pub def mesh_cube (half : F64) : MeshData := mesh_box half half half

/// At least a triangle's worth of segments.
def clamp_segments (n : I64) : I64 := if I64.lt n 3 then 3 else n

/// `n` ring vertices at height `y`, starting on +x and turning toward +z;
/// the uv is the ring's own unit disc.
#[terminating]
def ring_go (r : F64) (y : F64) (step : F64) (n : I64) (i : I64) : List F64 :=
    if I64.lt i n
    then
        let a : F64 := step * f64_of_i64 i in
        let c : F64 := f64_cos a in
        let s : F64 := f64_sin a in
        List.append [r * c, y, r * s, 0.5 + 0.5 * c, 0.5 + 0.5 * s]
                    (ring_go r y step n (I64.add i 1))
    else []

/// A fan around `center` over the `n` ring vertices that follow it. `up`
/// picks the winding: true faces +y, false faces -y.
#[terminating]
def fan_go (center : I64) (n : I64) (i : I64) (up : Bool) : List I64 :=
    if I64.lt i n
    then
        let cur : I64 := I64.add (I64.add center 1) i in
        let next : I64 := I64.add (I64.add center 1) (I64.rem (I64.add i 1) n) in
        let tri : List I64 := if up then [center, next, cur] else [center, cur, next] in
        List.append tri (fan_go center n (I64.add i 1) up)
    else []

/// A flat disc of `segments` wedges in the XZ plane, facing +y.
pub def mesh_disc (radius : F64) (segments : I64) : MeshData :=
    let n : I64 := clamp_segments segments in
    let step : F64 := f64_tau / f64_of_i64 n in
    mesh_data
        (List.append [0.0, 0.0, 0.0, 0.5, 0.5] (ring_go radius 0.0 step n 0))
        (fan_go 0 n 0 true)

/// The side wall's vertex columns: bottom then top, `n + 1` columns so the
/// seam has both `u = 0` and `u = 1`.
#[terminating]
def wall_go (r : F64) (half : F64) (step : F64) (n : I64) (i : I64) : List F64 :=
    if I64.lt n i
    then []
    else
        let a : F64 := step * f64_of_i64 i in
        let x : F64 := r * f64_cos a in
        let z : F64 := r * f64_sin a in
        let u : F64 := f64_of_i64 i / f64_of_i64 n in
        List.append [x, 0.0 - half, z, u, 0.0, x, half, z, u, 1.0]
                    (wall_go r half step n (I64.add i 1))

#[terminating]
def wall_indices (n : I64) (i : I64) : List I64 :=
    if I64.lt i n
    then
        let b : I64 := I64.mul i 2 in
        let t : I64 := I64.add b 1 in
        let b2 : I64 := I64.add b 2 in
        let t2 : I64 := I64.add b 3 in
        List.append [b, t, t2, b, t2, b2] (wall_indices n (I64.add i 1))
    else []

/// A capped cylinder along y: a wall, a +y cap and a -y cap.
pub def mesh_cylinder (radius : F64) (height : F64) (segments : I64) : MeshData :=
    let n : I64 := clamp_segments segments in
    let step : F64 := f64_tau / f64_of_i64 n in
    let half : F64 := height * 0.5 in
    let top_center : I64 := I64.mul (I64.add n 1) 2 in
    let bottom_center : I64 := I64.add (I64.add top_center 1) n in
    let top : List F64 := List.append [0.0, half, 0.0, 0.5, 0.5] (ring_go radius half step n 0) in
    let bottom : List F64 :=
        List.append [0.0, 0.0 - half, 0.0, 0.5, 0.5] (ring_go radius (0.0 - half) step n 0) in
    mesh_data
        (List.append (wall_go radius half step n 0) (List.append top bottom))
        (List.append (wall_indices n 0)
            (List.append (fan_go top_center n 0 true) (fan_go bottom_center n 0 false)))

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_quad_counts : Bool :=
    let m : MeshData := mesh_quad 2.0 1.0 in
    I64.beq (mesh_vertex_count m) 4 && I64.beq (mesh_triangle_count m) 2 && mesh_is_valid m

#[test]
def test_quad_first_vertex_layout : Bool :=
    // x y z u v of the bottom-left corner.
    match List.get 0 (mesh_vertices (mesh_quad 2.0 1.0)) {
        Option.some x => F64.beq x (0.0 - 1.0),
        Option.none => false
    }

#[test]
def test_box_counts : Bool :=
    let m : MeshData := mesh_box 1.0 2.0 3.0 in
    I64.beq (mesh_vertex_count m) 24 && I64.beq (mesh_index_count m) 36 && mesh_is_valid m

#[test]
def test_box_bounds_are_its_half_extents : Bool :=
    let b : AABB := mesh_bounds (mesh_box 1.0 2.0 3.0) in
    F64.beq b.min.x (0.0 - 1.0) && F64.beq b.min.y (0.0 - 2.0) && F64.beq b.min.z (0.0 - 3.0)
        && F64.beq b.max.x 1.0 && F64.beq b.max.y 2.0 && F64.beq b.max.z 3.0

#[test]
def test_disc_counts : Bool :=
    let m : MeshData := mesh_disc 1.0 8 in
    I64.beq (mesh_vertex_count m) 9 && I64.beq (mesh_triangle_count m) 8 && mesh_is_valid m

#[test]
def test_disc_clamps_to_a_triangle : Bool :=
    I64.beq (mesh_triangle_count (mesh_disc 1.0 1)) 3

#[test]
def test_cylinder_counts : Bool :=
    let m : MeshData := mesh_cylinder 1.0 2.0 8 in
    // wall 2(n+1) + two caps (n+1) = 4n + 4; wall 2n + caps 2n triangles.
    I64.beq (mesh_vertex_count m) 36 && I64.beq (mesh_triangle_count m) 32 && mesh_is_valid m

#[test]
def test_cylinder_bounds : Bool :=
    let b : AABB := mesh_bounds (mesh_cylinder 1.0 4.0 12) in
    F64.beq b.min.y (0.0 - 2.0) && F64.beq b.max.y 2.0 && b.max.x > 0.9999 && b.max.x < 1.0001

#[test]
def test_an_index_past_the_end_is_invalid : Bool :=
    Bool.not (mesh_is_valid (mesh_data [0.0, 0.0, 0.0, 0.0, 0.0] [0, 1, 2]))

#[test]
def test_empty_mesh_bounds_are_degenerate : Bool :=
    let b : AABB := mesh_bounds (mesh_data [] []) in
    F64.beq b.min.x 0.0 && F64.beq b.max.x 0.0
