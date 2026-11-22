// forge-collide: the kinematic character controller.
//
// `move_and_slide` moves an upright shape (a capsule, usually) by a desired
// displacement through a `Scene`, the way a game character moves:
//
// 1. Push out of anything the shape already overlaps.
// 2. Shape-cast along the motion, the horizontal part first and then the
//    vertical (so walking never grazes the floor it stands on, which
//    would cost conservative advancement many steps). On a hit, stop `skin` short,
//    then keep the part of the motion that runs along the surface. Up to 4
//    hits per move. A surface whose normal points up by more than
//    `ground_y` is ground. Against anything steeper while grounded, the
//    controller first tries to STEP up by at most `step`; failing that it
//    slides along the wall without climbing it.
// 3. A grounded mover that is not moving up is SNAPPED down by up to
//    `snap` so it follows slopes and small drops instead of skipping off
//    them.
//
// It never touches velocities. The caller owns them and reads `grounded`,
// `hit_wall` and `hit_ceiling` to zero what it must.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {Entity}
use forge_math {Vec3, vec3, v3_zero, v3_add, v3_sub, v3_scale, v3_dot, v3_length, v3_normalize, f64_max, f64_min}
use lib::shape {Shape, Pose, pose_at, layer_all}
use lib::world {Scene}
use lib::query {Hit, shape_cast, penetrations, Push}

/// Controller tuning. `Copy`.
#[derive Copy Clone]
pub struct MoveConfig {
    skin : F64,
    step : F64,
    snap : F64,
    ground_y : F64,
    mask : I64
}

/// 1 cm skin, 0.3 step, 0.2 snap, ground up to about 45 degrees.
pub def move_config_default : MoveConfig :=
    { skin := 0.01, step := 0.3, snap := 0.2, ground_y := 0.7, mask := layer_all : MoveConfig }

pub def move_config (skin : F64) (step : F64) (snap : F64) (ground_y : F64) (mask : I64) : MoveConfig :=
    { skin := skin, step := step, snap := snap, ground_y := ground_y, mask := mask : MoveConfig }

/// Where the move ended and what it touched. `Copy`.
pub struct Slide {
    position : Vec3,
    grounded : Bool,
    ground_normal : Vec3,
    ground : Option Entity,
    hit_wall : Bool,
    wall : Option Entity,
    hit_ceiling : Bool
}

pub instance Copy Slide {
    def copy (s : Slide) : Pair Slide Slide := Pair.pair s s
}

pub def slide_position (s : Slide) : Vec3 := s.position

pub def slide_grounded (s : Slide) : Bool := s.grounded

pub def slide_ground_normal (s : Slide) : Vec3 := s.ground_normal

pub def slide_ground (s : Slide) : Option Entity := s.ground

pub def slide_hit_wall (s : Slide) : Bool := s.hit_wall

pub def slide_wall (s : Slide) : Option Entity := s.wall

pub def slide_hit_ceiling (s : Slide) : Bool := s.hit_ceiling

def slide_at (p : Vec3) : Slide :=
    { position := p, grounded := false, ground_normal := vec3 0.0 1.0 0.0, ground := Option.none,
      hit_wall := false, wall := Option.none, hit_ceiling := false : Slide }

def with_pos (s : Slide) (p : Vec3) : Slide :=
    { position := p, grounded := s.grounded, ground_normal := s.ground_normal, ground := s.ground,
      hit_wall := s.hit_wall, wall := s.wall, hit_ceiling := s.hit_ceiling : Slide }

def with_ground (s : Slide) (n : Vec3) (e : Entity) : Slide :=
    { position := s.position, grounded := true, ground_normal := n, ground := Option.some e,
      hit_wall := s.hit_wall, wall := s.wall, hit_ceiling := s.hit_ceiling : Slide }

def with_wall (s : Slide) (e : Entity) : Slide :=
    { position := s.position, grounded := s.grounded, ground_normal := s.ground_normal, ground := s.ground,
      hit_wall := true, wall := Option.some e, hit_ceiling := s.hit_ceiling : Slide }

def with_ceiling (s : Slide) : Slide :=
    { position := s.position, grounded := s.grounded, ground_normal := s.ground_normal, ground := s.ground,
      hit_wall := s.hit_wall, wall := s.wall, hit_ceiling := true : Slide }

/// Everything one move needs, bundled so the helpers stay small. `Copy`.
struct Mover {
    scene : Scene,
    self_e : Option Entity,
    shape : Shape,
    cfg : MoveConfig
}

instance Copy Mover {
    def copy (m : Mover) : Pair Mover Mover := Pair.pair m m
}

def cast (m : Mover) (p : Vec3) (dir : Vec3) (dist : F64) : Option Hit :=
    shape_cast m.scene m.shape (pose_at p) dir dist m.cfg.mask m.self_e

// ── 1. Depenetration ────────────────────────────────────────────────

#[terminating]
def deepest (best : Option Push) (ps : List Push) : Option Push :=
    match ps {
        List.empty => best,
        List.cons p rest =>
            match best {
                Option.none => deepest (Option.some p) rest,
                Option.some b0 => let b : Push := b0 in if p.depth > b.depth then deepest (Option.some p) rest else deepest (Option.some b) rest
            }
    }

#[terminating]
def depenetrate (m : Mover) (p : Vec3) (n : I64) : Vec3 :=
    if n > 4 then p
    else
        match deepest Option.none (penetrations m.scene m.shape (pose_at p) m.cfg.mask m.self_e) {
            Option.none => p,
            Option.some push0 => let push : Push := push0 in depenetrate m (v3_add p (v3_scale push.normal (push.depth + m.cfg.skin * 0.5))) (n + 1)
        }

// ── 2. Slide and step ───────────────────────────────────────────────

def flat (v : Vec3) : Vec3 := vec3 v.x 0.0 v.z

/// Remove the part of `v` that drives into `n`.
def clip_along (v : Vec3) (n : Vec3) : Vec3 :=
    let d : F64 := v3_dot v n in
    if d < 0.0 then v3_sub v (v3_scale n d) else v

/// Rise by up to `step`, move `h` across, settle back down onto ground.
def try_step (m : Mover) (p : Vec3) (h : Vec3) : Option Vec3 :=
    let hl : F64 := v3_length h in
    if hl < 0.000001 || m.cfg.step <= 0.0 then Option.none
    else
        let up : Vec3 := vec3 0.0 1.0 0.0 in
        let rise : F64 := match cast m p up m.cfg.step {
            Option.some hit0 => let hit : Hit := hit0 in f64_max 0.0 (hit.t - m.cfg.skin),
            Option.none => m.cfg.step
        } in
        let p1 : Vec3 := v3_add p (v3_scale up rise) in
        let hd : Vec3 := v3_scale h (1.0 / hl) in
        let go : F64 := match cast m p1 hd (hl + m.cfg.skin) {
            Option.some hit0 => let hit : Hit := hit0 in f64_max 0.0 (hit.t - m.cfg.skin),
            Option.none => hl
        } in
        if go < hl * 0.5 then Option.none
        else
            let p2 : Vec3 := v3_add p1 (v3_scale hd go) in
            match cast m p2 (vec3 0.0 (0.0 - 1.0) 0.0) (rise + m.cfg.skin * 2.0) {
                Option.some hit0 =>
                    let hit : Hit := hit0 in
                    if hit.normal.y >= m.cfg.ground_y
                    then Option.some (v3_sub p2 (vec3 0.0 (f64_max 0.0 (hit.t - m.cfg.skin)) 0.0))
                    else Option.none,
                Option.none => Option.none
            }

#[terminating]
def slide_go (m : Mover) (s : Slide) (rem : Vec3) (was_grounded : Bool) (n : I64) : Slide :=
    let len : F64 := v3_length rem in
    if n > 4 || len < 0.0000001 then s
    else
        let dir : Vec3 := v3_scale rem (1.0 / len) in
        match cast m s.position dir (len + m.cfg.skin) {
            Option.none => with_pos s (v3_add s.position rem),
            Option.some hit0 =>
                let hit : Hit := hit0 in
                let go : F64 := f64_min len (f64_max 0.0 (hit.t - m.cfg.skin)) in
                let s1 : Slide := with_pos s (v3_add s.position (v3_scale dir go)) in
                let left : Vec3 := v3_scale dir (len - go) in
                let nrm : Vec3 := hit.normal in
                if nrm.y >= m.cfg.ground_y
                then slide_go m (with_ground s1 nrm hit.entity) (clip_along left nrm) was_grounded (n + 1)
                else if nrm.y <= 0.0 - m.cfg.ground_y
                then slide_go m (with_ceiling s1) (clip_along left nrm) was_grounded (n + 1)
                else
                    let on_ground : Bool := was_grounded || s1.grounded in
                    let stepped : Option Vec3 := if on_ground then try_step m s1.position (flat left) else Option.none in
                    match stepped {
                        Option.some q =>
                            slide_go m (with_pos s1 q) (vec3 0.0 left.y 0.0) was_grounded (n + 1),
                        Option.none =>
                            let wn : Vec3 := if on_ground && v3_length (flat nrm) > 0.000001
                                             then v3_normalize (flat nrm) else nrm in
                            slide_go m (with_wall s1 hit.entity) (clip_along left wn) was_grounded (n + 1)
                    }
        }

// ── 3. Snap ─────────────────────────────────────────────────────────

def snap (m : Mover) (s : Slide) : Slide :=
    match cast m s.position (vec3 0.0 (0.0 - 1.0) 0.0) m.cfg.snap {
        Option.some hit0 =>
            let hit : Hit := hit0 in
            if hit.normal.y >= m.cfg.ground_y
            then with_ground (with_pos s (v3_sub s.position (vec3 0.0 (f64_max 0.0 (hit.t - m.cfg.skin)) 0.0)))
                             hit.normal hit.entity
            else s,
        Option.none => s
    }

/// Move `shape` (upright at `from`) by `motion` through `scene`, ignoring
/// the collider of `self_e`. `was_grounded` (last move's `grounded`)
/// enables stepping and snapping.
pub def move_and_slide (scene : Scene) (self_e : Option Entity) (shape : Shape) (cfg : MoveConfig)
    (from : Vec3) (motion : Vec3) (was_grounded : Bool) : Slide :=
    let m : Mover := { scene := scene, self_e := self_e, shape := shape, cfg := cfg : Mover } in
    let start : Vec3 := depenetrate m from 0 in
    let h : Slide := slide_go m (slide_at start) (flat motion) was_grounded 0 in
    let s : Slide := slide_go m h (vec3 0.0 motion.y 0.0) was_grounded 0 in
    if was_grounded && Bool.not s.grounded && motion.y <= 0.0 then snap m s else s
