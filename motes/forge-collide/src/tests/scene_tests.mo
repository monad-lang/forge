// forge-collide over a world: broad phase against brute force, raycasts,
// overlap and shape casts, the character controller, and contact events
// across frames.

use lib::{
    Pose, pose_at, pose_new, Shape, shape_sphere, shape_box, shape_capsule, shape_plane,
    Collider, collider, collider_trigger, collider_with_layers, set_collider, layer_all,
    Entry, entry_new, Scene, scene_of, scene_size, collision_scene,
    Candidate, candidate_a, candidate_b, entry_entity, broad_phase, brute_pairs, same_entity,
    Hit, hit_entity, hit_t, hit_normal, raycast, overlap, shape_cast,
    MoveConfig, move_config_default, move_config, Slide, slide_position, slide_grounded, slide_hit_wall,
    slide_ground, move_and_slide,
    PairKey, pair_key, key_in, contacts_started, contacts_ended, contacts_current,
    world_contacts, contacts_update, started_with, ended_with, touching_pairs
}
use forge_core::ecs {World, Entity, Spawned, empty_world, entity_new, entity_id, insert_component}
use init::copy {Copy}
use forge_math {Vec3, vec3, v3_distance, Ray, ray, Quat, quat_from_axis_angle, quat_identity, f64_abs, f64_of_i64}
use forge_scene {spawn_transform, transform_from_translation, transform_new, transform_name}

def near (a : F64) (b : F64) : Bool := f64_abs (a - b) < 0.0001

def ent (i : I64) : Entity := entity_new (I64.to_u64 i) 0u64

def solid (i : I64) (s : Shape) (p : Vec3) : Entry := entry_new (ent i) (collider s) (pose_at p)

def unit_cube : Shape := shape_box (vec3 0.5 0.5 0.5)

// ── Broad phase ─────────────────────────────────────────────────────

/// A scatter of 24 shapes on a grid with some overlaps, plus a floor plane.
#[terminating]
def scatter (i : I64) (acc : List Entry) : List Entry :=
    if i > 24 then acc
    else
        let fx : F64 := f64_of_i64 (I64.rem (i * 7) 5) in
        let fz : F64 := f64_of_i64 (I64.rem (i * 3) 4) in
        let fy : F64 := f64_of_i64 (I64.rem i 3) in
        let s : Shape := if I64.rem i 2 == 0 then unit_cube else shape_sphere 0.6 in
        scatter (i + 1) (List.cons (solid i s (vec3 (fx * 0.9) (fy * 0.8) (fz * 1.1))) acc)

def scatter_scene : Scene :=
    scene_of (List.cons (solid 99 (shape_plane (vec3 0.0 1.0 0.0) 0.0) (vec3 0.0 0.0 0.0)) (scatter 1 []))

def key_of (c : Candidate) : PairKey := pair_key (entry_entity (candidate_a c)) (entry_entity (candidate_b c))

#[terminating]
def keys (cs : List Candidate) : List PairKey :=
    match cs {
        List.empty => [],
        List.cons c rest => List.cons (key_of c) (keys rest)
    }

struct Keys {
    ks : List PairKey
}

instance Copy Keys {
    def copy (k : Keys) : Pair Keys Keys := Pair.pair k k
}

#[terminating]
def all_in (xs : List PairKey) (ys : Keys) : Bool :=
    match xs {
        List.empty => true,
        List.cons x rest => key_in x ys.ks && all_in rest ys
    }

#[test]
def test_broad_phase_equals_brute_force : Bool :=
    let b : Keys := { ks := keys (broad_phase scatter_scene) : Keys } in
    let r : Keys := { ks := keys (brute_pairs scatter_scene) : Keys } in
    List.length b.ks == List.length r.ks && all_in b.ks r && all_in r.ks b && List.length r.ks > 24

#[test]
def test_broad_phase_respects_layers : Bool :=
    let a : Entry := entry_new (ent 1) (collider_with_layers (collider unit_cube) 1 1) (pose_at (vec3 0.0 0.0 0.0)) in
    let b : Entry := entry_new (ent 2) (collider_with_layers (collider unit_cube) 2 2) (pose_at (vec3 0.5 0.0 0.0)) in
    List.length (broad_phase (scene_of [a, b])) == 0

// ── Queries ─────────────────────────────────────────────────────────

def row : Scene :=
    scene_of [solid 1 unit_cube (vec3 0.0 0.0 (0.0 - 5.0)),
              solid 2 (shape_sphere 1.0) (vec3 0.0 0.0 (0.0 - 10.0)),
              solid 3 (shape_capsule 0.5 1.0) (vec3 3.0 0.0 0.0),
              solid 4 (shape_plane (vec3 0.0 1.0 0.0) 0.0) (vec3 0.0 (0.0 - 2.0) 0.0)]

def hit_is (o : Option Hit) (id : I64) (t : F64) : Bool :=
    match o {
        Option.some h0 => let h : Hit := h0 in entity_id (hit_entity h) == I64.to_u64 id && near (hit_t h) t,
        Option.none => false
    }

#[test]
def test_raycast_hits_the_nearest_box : Bool :=
    hit_is (raycast row (ray (vec3 0.0 0.0 0.0) (vec3 0.0 0.0 (0.0 - 1.0))) 100.0 layer_all) 1 4.5

#[test]
def test_raycast_respects_max_t : Bool :=
    match raycast row (ray (vec3 0.0 0.0 0.0) (vec3 0.0 0.0 (0.0 - 1.0))) 4.0 layer_all {
        Option.some _ => false,
        Option.none => true
    }

#[test]
def test_raycast_capsule_by_marching : Bool :=
    hit_is (raycast row (ray (vec3 0.0 0.5 0.0) (vec3 1.0 0.0 0.0)) 100.0 layer_all) 3 2.5

#[test]
def test_raycast_plane_normal : Bool :=
    match raycast row (ray (vec3 5.0 3.0 5.0) (vec3 0.0 (0.0 - 1.0) 0.0)) 100.0 layer_all {
        Option.some h0 => let h : Hit := h0 in let n : Vec3 := hit_normal h in near (hit_t h) 5.0 && near n.y 1.0,
        Option.none => false
    }

#[test]
def test_overlap_finds_touching_colliders : Bool :=
    let found : List Entity := overlap row (shape_sphere 1.0) (pose_at (vec3 0.0 0.0 (0.0 - 6.0))) layer_all Option.none in
    List.length found == 1

#[test]
def test_shape_cast_stops_at_the_box : Bool :=
    hit_is (shape_cast row (shape_sphere 0.5) (pose_at (vec3 0.0 0.0 0.0)) (vec3 0.0 0.0 (0.0 - 1.0)) 100.0 layer_all Option.none)
           1 4.0

#[test]
def test_shape_cast_ignores_what_it_slides_along : Bool :=
    let floor : Scene := scene_of [solid 1 (shape_box (vec3 10.0 0.5 10.0)) (vec3 0.0 (0.0 - 0.5) 0.0)] in
    match shape_cast floor (shape_sphere 0.5) (pose_at (vec3 0.0 0.5 0.0)) (vec3 1.0 0.0 0.0) 3.0 layer_all Option.none {
        Option.some _ => false,
        Option.none => true
    }

// ── Character controller ────────────────────────────────────────────

def mo : Shape := shape_capsule 0.35 0.35

/// A floor top at y = 0, a 0.25 step at x = 2, a 1.0 ledge at x = -2 and a
/// wall along z = -3.
def course : Scene :=
    scene_of [solid 1 (shape_box (vec3 10.0 0.5 10.0)) (vec3 0.0 (0.0 - 0.5) 0.0),
              solid 2 (shape_box (vec3 1.0 0.125 3.0)) (vec3 3.0 0.125 0.0),
              solid 3 (shape_box (vec3 1.0 0.5 3.0)) (vec3 (0.0 - 3.0) 0.5 0.0),
              solid 4 (shape_box (vec3 10.0 2.0 0.5)) (vec3 0.0 2.0 (0.0 - 3.5))]

/// Feet at y = 0: the capsule's centre is 0.7 up.
def stand : F64 := 0.7

def move (from : Vec3) (motion : Vec3) (grounded : Bool) : Slide :=
    move_and_slide course (Option.none) mo move_config_default from motion grounded

#[test]
def test_controller_lands_on_the_floor : Bool :=
    let s : Slide := move (vec3 0.0 2.0 0.0) (vec3 0.0 (0.0 - 3.0) 0.0) false in
    let p : Vec3 := slide_position s in
    slide_grounded s && near p.y (stand + 0.01)

#[test]
def test_controller_slides_along_a_wall : Bool :=
    let s : Slide := move (vec3 0.0 stand (0.0 - 2.0)) (vec3 0.5 0.0 (0.0 - 1.0)) true in
    let p : Vec3 := slide_position s in
    slide_hit_wall s && p.z > (0.0 - 2.66) && p.x > 0.45

#[test]
def test_controller_climbs_a_step : Bool :=
    let s : Slide := move (vec3 1.5 (stand + 0.01) 0.0) (vec3 0.5 (0.0 - 0.05) 0.0) true in
    let p : Vec3 := slide_position s in
    p.x > 1.95 && near p.y (stand + 0.25 + 0.01) && slide_grounded s

#[test]
def test_controller_does_not_climb_a_ledge : Bool :=
    let s : Slide := move (vec3 (0.0 - 1.5) (stand + 0.01) 0.0) (vec3 (0.0 - 0.5) (0.0 - 0.05) 0.0) true in
    let p : Vec3 := slide_position s in
    slide_hit_wall s && p.x > (0.0 - 1.66) && p.y < stand + 0.05

#[test]
def test_controller_slides_down_a_steep_slope : Bool :=
    let q : Quat := quat_from_axis_angle (vec3 0.0 0.0 1.0) 1.0471975511965976 in
    let slope : Scene := scene_of [entry_new (ent 1) (collider (shape_box (vec3 5.0 0.5 5.0))) (pose_new (vec3 0.0 0.0 0.0) q)] in
    let s0 : Vec3 := vec3 0.0 2.5 0.0 in
    let s : Slide := move_and_slide slope Option.none mo move_config_default s0 (vec3 0.0 (0.0 - 2.0) 0.0) false in
    let p : Vec3 := slide_position s in
    Bool.not (slide_grounded s) && p.y < 2.0 && f64_abs p.x > 0.05

#[test]
def test_controller_snaps_down_a_small_drop : Bool :=
    let cfg : MoveConfig := move_config 0.01 0.3 0.3 0.7 layer_all in
    let s : Slide := move_and_slide course Option.none mo cfg (vec3 3.5 (stand + 0.26) 0.0) (vec3 1.5 (0.0 - 0.01) 0.0) true in
    let p : Vec3 := slide_position s in
    slide_grounded s && near p.y (stand + 0.01)

#[test]
def test_controller_ignores_its_own_collider : Bool :=
    let me : Entry := solid 7 mo (vec3 0.0 stand 0.0) in
    let sc : Scene := scene_of [me, solid 1 (shape_box (vec3 10.0 0.5 10.0)) (vec3 0.0 (0.0 - 0.5) 0.0)] in
    let s : Slide := move_and_slide sc (Option.some (ent 7)) mo move_config_default (vec3 0.0 (stand + 0.01) 0.0) (vec3 1.0 0.0 0.0) true in
    let p : Vec3 := slide_position s in
    near p.x 1.0

// ── Contact events ──────────────────────────────────────────────────

struct Two {
    world : World,
    a : Entity,
    b : Entity
}

instance Copy Two {
    def copy (t : Two) : Pair Two Two := Pair.pair t t
}

def spawn_with (w : World) (p : Vec3) (c : Collider) : Spawned :=
    let s : Spawned := spawn_transform w (transform_from_translation p) in
    { world := set_collider s.world s.entity c, entity := s.entity : Spawned }

def two : Two :=
    let a : Spawned := spawn_with empty_world (vec3 0.0 0.0 0.0) (collider (shape_sphere 1.0)) in
    let b : Spawned := spawn_with a.world (vec3 5.0 0.0 0.0) (collider_trigger (shape_sphere 1.0)) in
    { world := b.world, a := a.entity, b := b.entity : Two }

def put (w : World) (e : Entity) (p : Vec3) : World :=
    insert_component w e transform_name (Any.any (transform_from_translation p))

#[test]
def test_contact_events_start_stay_end : Bool :=
    let t : Two := two in
    let f1 : World := contacts_update t.world in
    let f2 : World := contacts_update (put f1 t.b (vec3 1.5 0.0 0.0)) in
    let f3 : World := contacts_update f2 in
    let f4 : World := contacts_update (put f3 t.b (vec3 5.0 0.0 0.0)) in
    List.length (contacts_current (world_contacts f1)) == 0
        && List.length (started_with f2 t.a) == 1
        && List.length (started_with f3 t.a) == 0
        && List.length (contacts_current (world_contacts f3)) == 1
        && List.length (ended_with f4 t.b) == 1

#[test]
def test_collision_scene_reads_the_world : Bool :=
    let t : Two := two in
    scene_size (collision_scene t.world) == 2

// ── Budget ──────────────────────────────────────────────────────────

/// 200 colliders on a 20 x 10 grid, each touching its neighbours: the
/// Phase 10 budget is broad + narrow phase for these in well under a 60 Hz
/// frame. The runner prints the time.
#[terminating]
def grid (i : I64) (acc : List Entry) : List Entry :=
    if i >= 200 then acc
    else
        let x : F64 := f64_of_i64 (I64.rem i 20) in
        let z : F64 := f64_of_i64 (I64.div i 20) in
        let s : Shape := if I64.rem i 3 == 0 then shape_sphere 0.55 else if I64.rem i 3 == 1 then unit_cube else shape_capsule 0.3 0.4 in
        grid (i + 1) (List.cons (solid i s (vec3 (x * 0.8) 0.0 (z * 0.8))) acc)

#[test]
def test_budget_200_colliders_touching_pairs : Bool :=
    List.length (touching_pairs (scene_of (grid 0 []))) > 200
