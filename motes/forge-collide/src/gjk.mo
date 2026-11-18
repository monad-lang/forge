// forge-collide: GJK (distance between convex cores) and EPA (penetration
// depth when the cores overlap).
//
// Both work on the Minkowski difference A - B of two support-mapped cores
// (`support_core_world`); margins are added by the caller (`narrow.mo`).
//
// GJK keeps a simplex of up to 4 vertices of A - B and repeatedly replaces
// it by the sub-simplex whose closest point to the origin is nearest
// (Ericson, "Real-Time Collision Detection", 5.1.5 and 9.5). Every vertex
// remembers its A and B points, so the witness points come out of the same
// barycentric weights.
//
// EPA starts from a tetrahedron around the origin and grows the polytope
// toward the face nearest the origin until the support point stops moving
// it. Faces are oriented away from the starting tetrahedron's centroid,
// which stays inside as the polytope grows.

use std::derive {}
use init::copy {Copy}
use forge_math {
    Vec3, vec3, v3_zero, v3_add, v3_sub, v3_scale, v3_neg, v3_dot, v3_cross,
    v3_length, v3_length_sq, v3_normalize, f64_abs, f64_sqrt
}
use lib::shape {Shape, Pose, support_core_world, pose_pos}

// ── Minkowski vertices ──────────────────────────────────────────────

/// A vertex of A - B with its A and B points and an id for edge matching.
#[derive Copy Clone]
pub struct SV {
    w : Vec3,
    a : Vec3,
    b : Vec3,
    id : I64
}

/// The two posed cores GJK and EPA query. `Copy`.
pub struct Pair2 {
    sa : Shape,
    xa : Pose,
    sb : Shape,
    xb : Pose
}

pub instance Copy Pair2 {
    def copy (p : Pair2) : Pair Pair2 Pair2 := Pair.pair p p
}

pub def pair2 (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Pair2 :=
    { sa := sa, xa := xa, sb := sb, xb := xb : Pair2 }

/// The vertex of A - B farthest along `d`.
def support (p : Pair2) (d : Vec3) (id : I64) : SV :=
    let a : Vec3 := support_core_world p.sa p.xa d in
    let b : Vec3 := support_core_world p.sb p.xb (v3_neg d) in
    { w := v3_sub a b, a := a, b := b, id := id : SV }

// ── Closest point on a simplex ──────────────────────────────────────

/// A sub-simplex, its closest point `v` to the origin and the witnesses.
pub struct Reduced {
    v : Vec3,
    pa : Vec3,
    pb : Vec3,
    verts : List SV,
    inside : Bool
}

pub instance Copy Reduced {
    def copy (r : Reduced) : Pair Reduced Reduced := Pair.pair r r
}

def red1 (a : SV) : Reduced :=
    { v := a.w, pa := a.a, pb := a.b, verts := [a], inside := false : Reduced }

def red2 (a : SV) (b : SV) (t : F64) : Reduced :=
    let s : F64 := 1.0 - t in
    { v := v3_add (v3_scale a.w s) (v3_scale b.w t),
      pa := v3_add (v3_scale a.a s) (v3_scale b.a t),
      pb := v3_add (v3_scale a.b s) (v3_scale b.b t),
      verts := [a, b], inside := false : Reduced }

def red3 (a : SV) (b : SV) (c : SV) (u : F64) (v : F64) (w : F64) : Reduced :=
    { v := v3_add (v3_scale a.w u) (v3_add (v3_scale b.w v) (v3_scale c.w w)),
      pa := v3_add (v3_scale a.a u) (v3_add (v3_scale b.a v) (v3_scale c.a w)),
      pb := v3_add (v3_scale a.b u) (v3_add (v3_scale b.b v) (v3_scale c.b w)),
      verts := [a, b, c], inside := false : Reduced }

def closest_segment (a : SV) (b : SV) : Reduced :=
    let ab : Vec3 := v3_sub b.w a.w in
    let den : F64 := v3_dot ab ab in
    if den < 0.000000000001 then red1 a
    else
        let t : F64 := (0.0 - v3_dot a.w ab) / den in
        if t <= 0.0 then red1 a
        else if t >= 1.0 then red1 b
        else red2 a b t

/// Ericson's ClosestPtPointTriangle with the query point at the origin.
def closest_triangle (a : SV) (b : SV) (c : SV) : Reduced :=
    let ab : Vec3 := v3_sub b.w a.w in
    let ac : Vec3 := v3_sub c.w a.w in
    let ap : Vec3 := v3_neg a.w in
    let d1 : F64 := v3_dot ab ap in
    let d2 : F64 := v3_dot ac ap in
    if d1 <= 0.0 && d2 <= 0.0 then red1 a
    else
        let bp : Vec3 := v3_neg b.w in
        let d3 : F64 := v3_dot ab bp in
        let d4 : F64 := v3_dot ac bp in
        if d3 >= 0.0 && d4 <= d3 then red1 b
        else
            let vc : F64 := d1 * d4 - d3 * d2 in
            if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 then red2 a b (d1 / (d1 - d3))
            else
                let cp : Vec3 := v3_neg c.w in
                let d5 : F64 := v3_dot ab cp in
                let d6 : F64 := v3_dot ac cp in
                if d6 >= 0.0 && d5 <= d6 then red1 c
                else
                    let vb : F64 := d5 * d2 - d1 * d6 in
                    if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 then red2 a c (d2 / (d2 - d6))
                    else
                        let va : F64 := d3 * d6 - d5 * d4 in
                        if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0
                        then red2 b c ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
                        else
                            let den : F64 := va + vb + vc in
                            if f64_abs den < 0.000000000001 then closest_segment a b
                            else
                                let v : F64 := vb / den in
                                let w : F64 := vc / den in
                                red3 a b c (1.0 - v - w) v w

/// Is the origin on the other side of face `abc` from `d`?
def origin_outside (a : Vec3) (b : Vec3) (c : Vec3) (d : Vec3) : Bool :=
    let n : Vec3 := v3_cross (v3_sub b a) (v3_sub c a) in
    let so : F64 := v3_dot (v3_neg a) n in
    let sd : F64 := v3_dot (v3_sub d a) n in
    so * sd < 0.0 || f64_abs sd < 0.000000000001

def nearer (r : Reduced) (s : Reduced) : Reduced :=
    if v3_length_sq s.v < v3_length_sq r.v then s else r

def far_reduced : Reduced :=
    { v := vec3 1000000000.0 0.0 0.0, pa := v3_zero, pb := v3_zero, verts := [], inside := false
      : Reduced }

def closest_tetra (a : SV) (b : SV) (c : SV) (d : SV) : Reduced :=
    let oa : Bool := origin_outside a.w b.w c.w d.w in
    let ob : Bool := origin_outside a.w c.w d.w b.w in
    let oc : Bool := origin_outside a.w d.w b.w c.w in
    let od : Bool := origin_outside b.w d.w c.w a.w in
    if Bool.not (oa || ob || oc || od)
    then { v := v3_zero, pa := v3_zero, pb := v3_zero, verts := [a, b, c, d], inside := true
           : Reduced }
    else
        let r0 : Reduced := far_reduced in
        let r1 : Reduced := if oa then nearer r0 (closest_triangle a b c) else r0 in
        let r2 : Reduced := if ob then nearer r1 (closest_triangle a c d) else r1 in
        let r3 : Reduced := if oc then nearer r2 (closest_triangle a d b) else r2 in
        if od then nearer r3 (closest_triangle b d c) else r3

def closest_on (vs : List SV) : Reduced :=
    match vs {
        List.cons a r1 =>
            match r1 {
                List.empty => red1 a,
                List.cons b r2 =>
                    match r2 {
                        List.empty => closest_segment a b,
                        List.cons c r3 =>
                            match r3 {
                                List.empty => closest_triangle a b c,
                                List.cons d _ => closest_tetra a b c d
                            }
                    }
            },
        List.empty => far_reduced
    }

// ── GJK ─────────────────────────────────────────────────────────────

/// The result of a GJK query. When `overlap` is false, `distance` is the
/// core-to-core gap, `normal` points from A to B and `pa`/`pb` are the
/// closest points. When true, `simplex` encloses the origin for EPA.
pub struct Gjk {
    overlap : Bool,
    distance : F64,
    normal : Vec3,
    pa : Vec3,
    pb : Vec3,
    simplex : List SV
}

pub instance Copy Gjk {
    def copy (g : Gjk) : Pair Gjk Gjk := Pair.pair g g
}

def gjk_overlap (vs : List SV) : Gjk :=
    { overlap := true, distance := 0.0, normal := vec3 0.0 1.0 0.0, pa := v3_zero, pb := v3_zero,
      simplex := vs : Gjk }

def gjk_apart (r : Reduced) : Gjk :=
    let len : F64 := v3_length r.v in
    { overlap := false, distance := len, normal := v3_scale r.v (0.0 - 1.0 / len),
      pa := r.pa, pb := r.pb, simplex := [] : Gjk }

def gjk_eps : F64 := 0.0000000001

#[terminating]
def gjk_go (p : Pair2) (r : Reduced) (iter : I64) : Gjk :=
    let vv : F64 := v3_length_sq r.v in
    if vv < gjk_eps then gjk_overlap r.verts
    else if iter > 48 then gjk_apart r
    else
        let w : SV := support p (v3_neg r.v) iter in
        if vv - v3_dot r.v w.w <= 0.0000000001 * vv + 0.0000000000001 then gjk_apart r
        else
            let next : Reduced := closest_on (List.append r.verts [w]) in
            if next.inside then gjk_overlap next.verts
            else if v3_length_sq next.v >= vv * 0.999999999999 then gjk_apart r
            else gjk_go p next (iter + 1)

/// GJK between the cores of `p`.
pub def gjk (p : Pair2) : Gjk :=
    let d0 : Vec3 := v3_sub (pose_pos p.xb) (pose_pos p.xa) in
    let d : Vec3 := if v3_length_sq d0 < 0.000000000001 then vec3 1.0 0.0 0.0 else d0 in
    gjk_go p (red1 (support p (v3_neg d) 0)) 1

pub def gjk_is_overlap (g : Gjk) : Bool := g.overlap

pub def gjk_distance (g : Gjk) : F64 := g.distance

pub def gjk_normal (g : Gjk) : Vec3 := g.normal

pub def gjk_pa (g : Gjk) : Vec3 := g.pa

pub def gjk_pb (g : Gjk) : Vec3 := g.pb

// ── EPA ─────────────────────────────────────────────────────────────

/// A polytope face: outward unit normal `n`, distance `d` from the origin.
#[derive Copy Clone]
struct Face {
    a : SV,
    b : SV,
    c : SV,
    n : Vec3,
    d : F64
}

#[derive Copy Clone]
struct Edge {
    p : SV,
    q : SV
}

/// A face oriented away from `center` (inside the polytope).
def make_face (a : SV) (b : SV) (c : SV) (center : Vec3) : Face :=
    let raw : Vec3 := v3_cross (v3_sub b.w a.w) (v3_sub c.w a.w) in
    let len : F64 := v3_length raw in
    let n0 : Vec3 := if len < 0.000000000001 then v3_normalize (v3_sub a.w center) else v3_scale raw (1.0 / len) in
    if v3_dot n0 (v3_sub a.w center) < 0.0
    then let n : Vec3 := v3_neg n0 in { a := a, b := c, c := b, n := n, d := v3_dot n a.w : Face }
    else { a := a, b := b, c := c, n := n0, d := v3_dot n0 a.w : Face }

#[terminating]
def nearest_face (best : Face) (fs : List Face) : Face :=
    match fs {
        List.empty => best,
        List.cons f rest => if f.d < best.d then nearest_face f rest else nearest_face best rest
    }

def same_edge (e : Edge) (p : SV) (q : SV) : Bool := e.p.id == p.id && e.q.id == q.id

/// Add the directed edge `p -> q`, cancelling its reverse if present (an
/// edge shared by two removed faces is interior, not horizon).
#[terminating]
def edge_toggle (es : List Edge) (p : SV) (q : SV) : List Edge :=
    match es {
        List.empty => [{ p := p, q := q : Edge }],
        List.cons e rest =>
            if same_edge e q p then rest else List.cons e (edge_toggle rest p q)
    }

def face_edges (es : List Edge) (f : Face) : List Edge :=
    edge_toggle (edge_toggle (edge_toggle es f.a f.b) f.b f.c) f.c f.a

/// Faces `w` sees go to the horizon; the rest are kept.
struct Split {
    kept : List Face,
    horizon : List Edge
}

instance Copy Split {
    def copy (s : Split) : Pair Split Split := Pair.pair s s
}

/// The polytope's faces, `Copy` so a step can both search and split them.
struct Poly {
    faces : List Face
}

instance Copy Poly {
    def copy (p : Poly) : Pair Poly Poly := Pair.pair p p
}

#[terminating]
def split_go (w : Vec3) (fs : List Face) (kept : List Face) (hz : List Edge) : Split :=
    match fs {
        List.empty => { kept := kept, horizon := hz : Split },
        List.cons f rest =>
            if v3_dot f.n (v3_sub w f.a.w) > 0.0
            then split_go w rest kept (face_edges hz f)
            else split_go w rest (List.cons f kept) hz
    }

#[terminating]
def cone (w : SV) (center : Vec3) (es : List Edge) (fs : List Face) : List Face :=
    match es {
        List.empty => fs,
        List.cons e rest => cone w center rest (List.cons (make_face e.p e.q w center) fs)
    }

/// Penetration: depth along `normal` (from A to B) and witness points.
pub struct Epa {
    depth : F64,
    normal : Vec3,
    pa : Vec3,
    pb : Vec3
}

pub instance Copy Epa {
    def copy (e : Epa) : Pair Epa Epa := Pair.pair e e
}

/// Barycentric weights of `p` (on the face's plane) in `abc`.
def epa_result (f : Face) : Epa :=
    let p : Vec3 := v3_scale f.n f.d in
    let v0 : Vec3 := v3_sub f.b.w f.a.w in
    let v1 : Vec3 := v3_sub f.c.w f.a.w in
    let v2 : Vec3 := v3_sub p f.a.w in
    let d00 : F64 := v3_dot v0 v0 in
    let d01 : F64 := v3_dot v0 v1 in
    let d11 : F64 := v3_dot v1 v1 in
    let d20 : F64 := v3_dot v2 v0 in
    let d21 : F64 := v3_dot v2 v1 in
    let den : F64 := d00 * d11 - d01 * d01 in
    let v : F64 := if f64_abs den < 0.000000000001 then 0.0 else (d11 * d20 - d01 * d21) / den in
    let w : F64 := if f64_abs den < 0.000000000001 then 0.0 else (d00 * d21 - d01 * d20) / den in
    let u : F64 := 1.0 - v - w in
    { depth := f.d, normal := f.n,
      pa := v3_add (v3_scale f.a.a u) (v3_add (v3_scale f.b.a v) (v3_scale f.c.a w)),
      pb := v3_add (v3_scale f.a.b u) (v3_add (v3_scale f.b.b v) (v3_scale f.c.b w))
      : Epa }

#[terminating]
def epa_go (p : Pair2) (center : Vec3) (poly : Poly) (first : Face) (iter : I64) : Epa :=
    let f : Face := nearest_face first poly.faces in
    let w : SV := support p f.n (100 + iter) in
    if v3_dot w.w f.n - f.d < 0.000001 || iter > 64 then epa_result f
    else
        let s : Split := split_go w.w poly.faces [] [] in
        let next : Poly := { faces := cone w center s.horizon s.kept : Poly } in
        match next.faces {
            List.cons h _ => epa_go p center next h (iter + 1),
            List.empty => epa_result f
        }

def tetra_faces (a : SV) (b : SV) (c : SV) (d : SV) : List Face :=
    let center : Vec3 := v3_scale (v3_add (v3_add a.w b.w) (v3_add c.w d.w)) 0.25 in
    [make_face a b c center, make_face a c d center, make_face a d b center, make_face b d c center]

def centroid4 (a : SV) (b : SV) (c : SV) (d : SV) : Vec3 :=
    v3_scale (v3_add (v3_add a.w b.w) (v3_add c.w d.w)) 0.25

/// A direction not parallel to `v`.
def perp_of (v : Vec3) : Vec3 :=
    let ax : Vec3 := if f64_abs v.x < 0.57 then vec3 1.0 0.0 0.0
                     else if f64_abs v.y < 0.57 then vec3 0.0 1.0 0.0 else vec3 0.0 0.0 1.0 in
    v3_cross v ax

/// A support point off the plane through the origin with normal `n`
/// (trying both sides).
def off_plane (p : Pair2) (n : Vec3) (id : I64) : SV :=
    let w : SV := support p n id in
    if f64_abs (v3_dot w.w n) > 0.0000001 then w else support p (v3_neg n) id

def epa_from_tetra (p : Pair2) (a : SV) (b : SV) (c : SV) (d : SV) : Epa :=
    let center : Vec3 := centroid4 a b c d in
    epa_go p center { faces := tetra_faces a b c d : Poly } (make_face a b c center) 0

def zero_epa (a : SV) : Epa :=
    { depth := 0.0, normal := vec3 0.0 1.0 0.0, pa := a.a, pb := a.b : Epa }

/// Grow a 1-, 2- or 3-vertex simplex to a tetrahedron, then run EPA.
def epa_from (p : Pair2) (vs : List SV) : Epa :=
    match vs {
        List.cons a r1 =>
            match r1 {
                List.empty =>
                    let b : SV := off_plane p (vec3 1.0 0.0 0.0) 91 in
                    let c : SV := off_plane p (perp_of (v3_sub b.w a.w)) 92 in
                    let n : Vec3 := v3_cross (v3_sub b.w a.w) (v3_sub c.w a.w) in
                    let d : SV := off_plane p n 93 in
                    epa_from_tetra p a b c d,
                List.cons b r2 =>
                    match r2 {
                        List.empty =>
                            let c : SV := off_plane p (perp_of (v3_sub b.w a.w)) 92 in
                            let n : Vec3 := v3_cross (v3_sub b.w a.w) (v3_sub c.w a.w) in
                            let d : SV := off_plane p n 93 in
                            epa_from_tetra p a b c d,
                        List.cons c r3 =>
                            match r3 {
                                List.empty =>
                                    let n : Vec3 := v3_cross (v3_sub b.w a.w) (v3_sub c.w a.w) in
                                    let d : SV := off_plane p n 93 in
                                    epa_from_tetra p a b c d,
                                List.cons d _ => epa_from_tetra p a b c d
                            }
                    }
            },
        List.empty => { depth := 0.0, normal := vec3 0.0 1.0 0.0, pa := v3_zero, pb := v3_zero : Epa }
    }

/// EPA on an overlapping GJK result.
pub def epa (p : Pair2) (g : Gjk) : Epa := epa_from p g.simplex

pub def epa_depth (e : Epa) : F64 := e.depth

pub def epa_normal (e : Epa) : Vec3 := e.normal

pub def epa_pa (e : Epa) : Vec3 := e.pa

pub def epa_pb (e : Epa) : Vec3 := e.pb
