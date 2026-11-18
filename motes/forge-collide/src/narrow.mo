// forge-collide: the narrow phase. `proximity` gives the signed distance
// between two posed shapes (negative when they overlap), the normal from A
// to B and a point on each surface; `collide` turns an overlap into a
// `Contact`.
//
// Closed forms where they are cheap and exact: anything against a plane,
// sphere and capsule pairs (closest points between their core segments),
// sphere against box, and box against box by SAT once GJK says the cores
// overlap. Every other pair goes through GJK on the cores, then EPA when the
// cores overlap; margins are added back afterwards.
//
// Not yet: the clipped multi-point box manifold. A contact is one point (the
// deepest). Phase 12's stacking work adds clipping when it needs it.

use std::derive {}
use init::copy {Copy}
use forge_math {
    Vec3, vec3, v3_zero, v3_add, v3_sub, v3_scale, v3_neg, v3_dot, v3_cross,
    v3_length, v3_length_sq, v3_normalize, f64_abs, f64_min, f64_max, f64_clamp
}
use lib::shape {
    Shape, Pose, pose_point, pose_dir, pose_inv_point, pose_inv_dir, pose_pos,
    shape_margin, support_world, plane_world
}
use lib::gjk {Pair2, pair2, Gjk, gjk, Epa, epa}

// ── Results ─────────────────────────────────────────────────────────

/// Signed separation of two shapes: `distance` < 0 is penetration depth.
/// `normal` (unit) points from A toward B; `pa`/`pb` lie on the surfaces.
#[derive Copy Clone]
pub struct Proximity {
    distance : F64,
    normal : Vec3,
    pa : Vec3,
    pb : Vec3
}

pub def proximity_new (distance : F64) (normal : Vec3) (pa : Vec3) (pb : Vec3) : Proximity :=
    { distance := distance, normal := normal, pa := pa, pb := pb : Proximity }

pub def prox_distance (p : Proximity) : F64 := p.distance

pub def prox_normal (p : Proximity) : Vec3 := p.normal

pub def prox_pa (p : Proximity) : Vec3 := p.pa

pub def prox_pb (p : Proximity) : Vec3 := p.pb

/// The same proximity seen from B.
pub def prox_flip (p : Proximity) : Proximity :=
    { distance := p.distance, normal := v3_neg p.normal, pa := p.pb, pb := p.pa : Proximity }

/// A touching or overlapping pair: `depth` >= 0 along `normal` (A to B).
#[derive Copy Clone]
pub struct Contact {
    normal : Vec3,
    depth : F64,
    point_a : Vec3,
    point_b : Vec3
}

pub def contact_normal (c : Contact) : Vec3 := c.normal

pub def contact_depth (c : Contact) : F64 := c.depth

pub def contact_point_a (c : Contact) : Vec3 := c.point_a

pub def contact_point_b (c : Contact) : Vec3 := c.point_b

def far_apart : Proximity :=
    { distance := 1000000000.0, normal := vec3 0.0 1.0 0.0, pa := v3_zero, pb := v3_zero : Proximity }

def unit_or_up (v : Vec3) : Vec3 :=
    let len : F64 := v3_length v in
    if len < 0.000000001 then vec3 0.0 1.0 0.0 else v3_scale v (1.0 / len)

/// Core proximity plus the two margins.
def with_margins (core : Proximity) (ma : F64) (mb : F64) : Proximity :=
    { distance := core.distance - ma - mb, normal := core.normal,
      pa := v3_add core.pa (v3_scale core.normal ma),
      pb := v3_sub core.pb (v3_scale core.normal mb)
      : Proximity }

// ── Segments (spheres and capsules) ─────────────────────────────────

#[derive Copy Clone]
struct Seg {
    p : Vec3,
    q : Vec3
}

def seg_of (s : Shape) (x : Pose) : Seg :=
    match s {
        Shape.capsule_shape _ hh =>
            { p := pose_point x (vec3 0.0 (0.0 - hh) 0.0), q := pose_point x (vec3 0.0 hh 0.0) : Seg },
        Shape.sphere_shape _ => { p := pose_pos x, q := pose_pos x : Seg },
        Shape.box_shape _ => { p := pose_pos x, q := pose_pos x : Seg },
        Shape.plane_shape _ _ => { p := pose_pos x, q := pose_pos x : Seg },
        Shape.convex_shape _ => { p := pose_pos x, q := pose_pos x : Seg }
    }

def is_round (s : Shape) : Bool :=
    match s {
        Shape.sphere_shape _ => true,
        Shape.capsule_shape _ _ => true,
        Shape.box_shape _ => false,
        Shape.plane_shape _ _ => false,
        Shape.convex_shape _ => false
    }

def is_sphere (s : Shape) : Bool :=
    match s {
        Shape.sphere_shape _ => true,
        Shape.capsule_shape _ _ => false,
        Shape.box_shape _ => false,
        Shape.plane_shape _ _ => false,
        Shape.convex_shape _ => false
    }

def is_box (s : Shape) : Bool :=
    match s {
        Shape.box_shape _ => true,
        Shape.sphere_shape _ => false,
        Shape.capsule_shape _ _ => false,
        Shape.plane_shape _ _ => false,
        Shape.convex_shape _ => false
    }

def is_plane (s : Shape) : Bool :=
    match s {
        Shape.plane_shape _ _ => true,
        Shape.sphere_shape _ => false,
        Shape.capsule_shape _ _ => false,
        Shape.box_shape _ => false,
        Shape.convex_shape _ => false
    }

def eps : F64 := 0.000000000001

/// Closest points between segments `a` and `b` (Ericson 5.1.9).
pub def seg_seg (ap : Vec3) (aq : Vec3) (bp : Vec3) (bq : Vec3) : Pair Vec3 Vec3 :=
    let d1 : Vec3 := v3_sub aq ap in
    let d2 : Vec3 := v3_sub bq bp in
    let r : Vec3 := v3_sub ap bp in
    let a : F64 := v3_dot d1 d1 in
    let e : F64 := v3_dot d2 d2 in
    let f : F64 := v3_dot d2 r in
    if a <= eps && e <= eps then Pair.pair ap bp
    else if a <= eps then Pair.pair ap (v3_add bp (v3_scale d2 (f64_clamp 0.0 1.0 (f / e))))
    else
        let c : F64 := v3_dot d1 r in
        if e <= eps then Pair.pair (v3_add ap (v3_scale d1 (f64_clamp 0.0 1.0 ((0.0 - c) / a)))) bp
        else
            let b : F64 := v3_dot d1 d2 in
            let den : F64 := a * e - b * b in
            let s0 : F64 := if den > eps then f64_clamp 0.0 1.0 ((b * f - c * e) / den) else 0.0 in
            let t0 : F64 := (b * s0 + f) / e in
            let st : Pair F64 F64 :=
                if t0 < 0.0 then Pair.pair (f64_clamp 0.0 1.0 ((0.0 - c) / a)) 0.0
                else if t0 > 1.0 then Pair.pair (f64_clamp 0.0 1.0 ((b - c) / a)) 1.0
                else Pair.pair s0 t0 in
            match st {
                Pair.pair s t => Pair.pair (v3_add ap (v3_scale d1 s)) (v3_add bp (v3_scale d2 t))
            }

def round_round (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Proximity :=
    let a : Seg := seg_of sa xa in
    let b : Seg := seg_of sb xb in
    with_ab_centres (seg_seg a.p a.q b.p b.q) (pose_pos xa) (pose_pos xb) (shape_margin sa) (shape_margin sb)

def with_ab_centres (cp : Pair Vec3 Vec3) (ca : Vec3) (cb : Vec3) (ma : F64) (mb : F64) : Proximity :=
    match cp {
        Pair.pair pa0 pb0 =>
            let pa : Vec3 := pa0 in
            let pb : Vec3 := pb0 in
            let d : Vec3 := v3_sub pb pa in
            let len : F64 := v3_length d in
            let n : Vec3 := if len < 0.000000001 then unit_or_up (v3_sub cb ca) else v3_scale d (1.0 / len) in
            with_margins { distance := len, normal := n, pa := pa, pb := pb : Proximity } ma mb
    }

// ── Point against box ───────────────────────────────────────────────

/// Signed proximity from the box (A) to the point (B).
def box_point (h : Vec3) (xb : Pose) (p : Vec3) : Proximity :=
    let l : Vec3 := pose_inv_point xb p in
    let q : Vec3 := vec3 (f64_clamp (0.0 - h.x) h.x l.x) (f64_clamp (0.0 - h.y) h.y l.y)
                         (f64_clamp (0.0 - h.z) h.z l.z) in
    let out : Vec3 := v3_sub l q in
    let olen : F64 := v3_length out in
    if olen > 0.000000001
    then { distance := olen, normal := pose_dir xb (v3_scale out (1.0 / olen)),
           pa := pose_point xb q, pb := p : Proximity }
    else
        let dx : F64 := h.x - f64_abs l.x in
        let dy : F64 := h.y - f64_abs l.y in
        let dz : F64 := h.z - f64_abs l.z in
        let sx : F64 := if l.x < 0.0 then 0.0 - 1.0 else 1.0 in
        let sy : F64 := if l.y < 0.0 then 0.0 - 1.0 else 1.0 in
        let sz : F64 := if l.z < 0.0 then 0.0 - 1.0 else 1.0 in
        if dx <= dy && dx <= dz
        then { distance := 0.0 - dx, normal := pose_dir xb (vec3 sx 0.0 0.0),
               pa := pose_point xb (vec3 (sx * h.x) l.y l.z), pb := p : Proximity }
        else if dy <= dz
        then { distance := 0.0 - dy, normal := pose_dir xb (vec3 0.0 sy 0.0),
               pa := pose_point xb (vec3 l.x (sy * h.y) l.z), pb := p : Proximity }
        else { distance := 0.0 - dz, normal := pose_dir xb (vec3 0.0 0.0 sz),
               pa := pose_point xb (vec3 l.x l.y (sz * h.z)), pb := p : Proximity }

def box_half (s : Shape) : Vec3 :=
    match s {
        Shape.box_shape h => h,
        Shape.sphere_shape _ => v3_zero,
        Shape.capsule_shape _ _ => v3_zero,
        Shape.plane_shape _ _ => v3_zero,
        Shape.convex_shape _ => v3_zero
    }

/// Box (A) against sphere (B).
def box_sphere (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Proximity :=
    let core : Proximity := box_point (box_half sa) xa (pose_pos xb) in
    with_margins core 0.0 (shape_margin sb)

// ── Plane ───────────────────────────────────────────────────────────

/// Plane (A) against any non-plane shape (B).
def plane_any (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Proximity :=
    match sa {
        Shape.plane_shape pn pd =>
            match plane_world pn pd xa {
                Pair.pair n0 d0 =>
                    let n : Vec3 := n0 in
                    let d : F64 := d0 in
                    let q : Vec3 := support_world sb xb (v3_neg n) in
                    let dist : F64 := v3_dot n q + d in
                    { distance := dist, normal := n, pa := v3_sub q (v3_scale n dist), pb := q : Proximity }
            },
        Shape.sphere_shape _ => far_apart,
        Shape.capsule_shape _ _ => far_apart,
        Shape.box_shape _ => far_apart,
        Shape.convex_shape _ => far_apart
    }

// ── Box against box (SAT) ───────────────────────────────────────────

/// The axis of least overlap so far.
#[derive Copy Clone]
struct Best {
    depth : F64,
    axis : Vec3
}

def project_radius (x : Pose) (h : Vec3) (l : Vec3) : F64 :=
    h.x * f64_abs (v3_dot (pose_dir x (vec3 1.0 0.0 0.0)) l)
        + h.y * f64_abs (v3_dot (pose_dir x (vec3 0.0 1.0 0.0)) l)
        + h.z * f64_abs (v3_dot (pose_dir x (vec3 0.0 0.0 1.0)) l)

def sat_axis (best : Best) (xa : Pose) (ha : Vec3) (xb : Pose) (hb : Vec3) (raw : Vec3) : Best :=
    let len : F64 := v3_length raw in
    if len < 0.000001 then best
    else
        let l : Vec3 := v3_scale raw (1.0 / len) in
        let t : F64 := v3_dot (v3_sub (pose_pos xb) (pose_pos xa)) l in
        let o : F64 := project_radius xa ha l + project_radius xb hb l - f64_abs t in
        if o < best.depth
        then { depth := o, axis := if t < 0.0 then v3_neg l else l : Best }
        else best

#[terminating]
def sat_crosses (best : Best) (xa : Pose) (ha : Vec3) (xb : Pose) (hb : Vec3) (aas : List Vec3) (bs : List Vec3) : Best :=
    match aas {
        List.empty => best,
        List.cons a rest =>
            let b1 : Best := sat_axis best xa ha xb hb (v3_cross a (pose_dir xb (vec3 1.0 0.0 0.0))) in
            let b2 : Best := sat_axis b1 xa ha xb hb (v3_cross a (pose_dir xb (vec3 0.0 1.0 0.0))) in
            let b3 : Best := sat_axis b2 xa ha xb hb (v3_cross a (pose_dir xb (vec3 0.0 0.0 1.0))) in
            sat_crosses b3 xa ha xb hb rest bs
    }

def box_box_sat (ha : Vec3) (xa : Pose) (sb : Shape) (hb : Vec3) (xb : Pose) : Proximity :=
    let ax : Vec3 := pose_dir xa (vec3 1.0 0.0 0.0) in
    let ay : Vec3 := pose_dir xa (vec3 0.0 1.0 0.0) in
    let az : Vec3 := pose_dir xa (vec3 0.0 0.0 1.0) in
    let b0 : Best := { depth := 1000000000.0, axis := vec3 0.0 1.0 0.0 : Best } in
    let b1 : Best := sat_axis (sat_axis (sat_axis b0 xa ha xb hb ax) xa ha xb hb ay) xa ha xb hb az in
    let b2 : Best := sat_axis (sat_axis (sat_axis b1 xa ha xb hb (pose_dir xb (vec3 1.0 0.0 0.0)))
                                        xa ha xb hb (pose_dir xb (vec3 0.0 1.0 0.0)))
                              xa ha xb hb (pose_dir xb (vec3 0.0 0.0 1.0)) in
    let b3 : Best := sat_crosses b2 xa ha xb hb [ax, ay, az] [] in
    let n : Vec3 := b3.axis in
    let pb : Vec3 := support_world sb xb (v3_neg n) in
    { distance := 0.0 - b3.depth, normal := n, pa := v3_add pb (v3_scale n b3.depth), pb := pb : Proximity }

// ── General convex (GJK / EPA) ──────────────────────────────────────

def from_gjk (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Proximity :=
    let p : Pair2 := pair2 sa xa sb xb in
    let g : Gjk := gjk p in
    if g.overlap
    then
        if is_box sa && is_box sb
        then box_box_sat (box_half sa) xa sb (box_half sb) xb
        else
            let e : Epa := epa p g in
            with_margins { distance := 0.0 - e.depth, normal := e.normal, pa := e.pa, pb := e.pb : Proximity }
                         (shape_margin sa) (shape_margin sb)
    else
        with_margins { distance := g.distance, normal := g.normal, pa := g.pa, pb := g.pb : Proximity }
                     (shape_margin sa) (shape_margin sb)

/// The closed-form-free path, exposed so tests can hold the closed forms
/// to it.
pub def proximity_gjk (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Proximity :=
    from_gjk sa xa sb xb

// ── Dispatch ────────────────────────────────────────────────────────

/// Signed proximity of two posed shapes.
pub def proximity (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Proximity :=
    if is_plane sa && is_plane sb then far_apart
    else if is_plane sa then plane_any sa xa sb xb
    else if is_plane sb then prox_flip (plane_any sb xb sa xa)
    else if is_round sa && is_round sb then round_round sa xa sb xb
    else if is_box sa && is_sphere sb then box_sphere sa xa sb xb
    else if is_sphere sa && is_box sb then prox_flip (box_sphere sb xb sa xa)
    else from_gjk sa xa sb xb

/// The contact of two overlapping (or touching) shapes.
pub def collide (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Option Contact :=
    let p : Proximity := proximity sa xa sb xb in
    if p.distance <= 0.0
    then Option.some { normal := p.normal, depth := 0.0 - p.distance, point_a := p.pa, point_b := p.pb : Contact }
    else Option.none

/// Do two posed shapes overlap?
pub def overlaps (sa : Shape) (xa : Pose) (sb : Shape) (xb : Pose) : Bool :=
    prox_distance (proximity sa xa sb xb) <= 0.0
