// Mo Venture: Mo, the hero.
//
// Mo is a capsule collider driven by forge-collide's kinematic controller.
// Each frame:
//
// 1. an `Intent` (where to run, jump/dash presses) comes from the keyboard
//    or from the autopilot (`bot.mo`);
// 2. `mo_velocity` turns intent into velocity: momentum on the ground and
//    in the air, jump with coyote time, buffering and a short-hop cut, one
//    air dash per jump, gravity;
// 3. `move_and_slide` moves Mo by `velocity * dt` through the level;
// 4. `mo_landed` reads what the move touched (ground, ceiling).
//
// All of it is pure; `mo_system` just reads and writes the world.

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math {
    Vec3, vec3, v3_zero, v3_add, v3_sub, v3_scale, v3_length, v3_normalize, v3_lerp,
    Quat, quat, f64_sqrt, f64_max, f64_min
}
use forge_scene {Transform, transform_new, transform_name, entity_transform}
use forge_schedule {world_time, time_delta}
use forge_collide {
    Scene, Shape, shape_capsule, collision_scene, move_and_slide, MoveConfig, move_config_default,
    Slide, slide_position, slide_grounded, slide_hit_ceiling, slide_ground
}
use lib::tune {Tune, tune, mo_radius, mo_half_height}

// ── Intent ──────────────────────────────────────────────────────────

/// What the player (or the autopilot) wants this frame. `mx`/`mz` is the
/// run direction in world space (length 0..1). `Copy`.
#[derive Copy Clone]
pub struct Intent {
    mx : F64,
    mz : F64,
    jump_pressed : Bool,
    jump_held : Bool,
    dash_pressed : Bool,
    sprint : Bool
}

pub def intent_none : Intent :=
    { mx := 0.0, mz := 0.0, jump_pressed := false, jump_held := false, dash_pressed := false,
      sprint := false : Intent }

pub def intent (mx : F64) (mz : F64) (jump_pressed : Bool) (jump_held : Bool) (dash_pressed : Bool)
    (sprint : Bool) : Intent :=
    { mx := mx, mz := mz, jump_pressed := jump_pressed, jump_held := jump_held,
      dash_pressed := dash_pressed, sprint := sprint : Intent }

pub def intent_move (i : Intent) : Vec3 := vec3 i.mx 0.0 i.mz

pub def intent_name : String := "mo.intent"

def as_intent (v : Any) : Intent :=
    match v { Any.any x => let i : Intent := x in i }

pub def world_intent (world : World) : Intent :=
    match List.first (query_entities world [intent_name] []) {
        Option.some e =>
            match get_component_named world e intent_name {
                Option.some v => as_intent v,
                Option.none => intent_none
            },
        Option.none => intent_none
    }

pub def world_set_intent (world : World) (i : Intent) : World :=
    match List.first (query_entities world [intent_name] []) {
        Option.some e => insert_component world e intent_name (Any.any i),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair intent_name (Any.any i)] in
            s.world
    }

// ── State ───────────────────────────────────────────────────────────

/// Mo's motion state. Timers count seconds since an event (large when it
/// is long past). `facing` is a unit vector on the ground plane. `Copy`.
#[derive Copy Clone]
pub struct MoState {
    vel : Vec3,
    grounded : Bool,
    since_ground : F64,
    since_press : F64,
    jumping : Bool,
    dashed : Bool,
    facing : Vec3
}

pub def long_ago : F64 := 100.0

/// At rest, on the ground, facing -z (into the level).
pub def mo_rest : MoState :=
    { vel := v3_zero, grounded := true, since_ground := 0.0, since_press := long_ago, jumping := false,
      dashed := false, facing := vec3 0.0 0.0 (0.0 - 1.0) : MoState }

/// Just left the ground (this frame), not having jumped.
pub def mo_airborne : MoState :=
    { vel := v3_zero, grounded := false, since_ground := 0.0, since_press := long_ago, jumping := false,
      dashed := false, facing := vec3 0.0 0.0 (0.0 - 1.0) : MoState }

pub def mo_vel (s : MoState) : Vec3 := s.vel

pub def mo_grounded (s : MoState) : Bool := s.grounded

pub def mo_dashed (s : MoState) : Bool := s.dashed

pub def mo_facing (s : MoState) : Vec3 := s.facing

def mk (vel : Vec3) (grounded : Bool) (since_ground : F64) (since_press : F64) (jumping : Bool)
    (dashed : Bool) (facing : Vec3) : MoState :=
    { vel := vel, grounded := grounded, since_ground := since_ground, since_press := since_press,
      jumping := jumping, dashed := dashed, facing := facing : MoState }

pub def mo_with_vel (s : MoState) (v : Vec3) : MoState :=
    mk v s.grounded s.since_ground s.since_press s.jumping s.dashed s.facing

// ── Velocity ────────────────────────────────────────────────────────

def flat (v : Vec3) : Vec3 := vec3 v.x 0.0 v.z

/// Move `v`'s horizontal part toward `target` by at most `step`.
def approach (v : Vec3) (target : Vec3) (step : F64) : Vec3 :=
    let d : Vec3 := v3_sub target (flat v) in
    let len : F64 := v3_length d in
    if len <= step then vec3 target.x v.y target.z
    else
        let moved : Vec3 := v3_add (flat v) (v3_scale d (step / len)) in
        vec3 moved.x v.y moved.z

def clamp_unit (v : Vec3) : Vec3 :=
    let len : F64 := v3_length v in
    if len > 1.0 then v3_scale v (1.0 / len) else v

/// Steering: accelerate toward the intended run velocity, with friction
/// when there is no intent on the ground.
def steer (t : Tune) (s : MoState) (i : Intent) (dt : F64) : Vec3 :=
    let m : Vec3 := clamp_unit (intent_move i) in
    let speed : F64 := if i.sprint then t.sprint_speed else t.run_speed in
    let wants : Bool := v3_length m > 0.01 in
    let rate : F64 := if s.grounded then (if wants then t.ground_accel else t.ground_friction) else t.air_accel in
    approach s.vel (v3_scale m speed) (rate * dt)

/// Turn `facing` toward the horizontal velocity.
def turn (t : Tune) (facing : Vec3) (vel : Vec3) (dt : F64) : Vec3 :=
    let h : Vec3 := flat vel in
    let len : F64 := v3_length h in
    if len < 0.3 then facing
    else
        let k : F64 := t.turn_rate * dt in
        let a : F64 := k / (1.0 + k) in
        let f : Vec3 := v3_lerp facing (v3_scale h (1.0 / len)) a in
        let fl : F64 := v3_length f in
        if fl < 0.0001 then v3_scale h (1.0 / len) else v3_scale f (1.0 / fl)

/// One frame of velocity, before the move.
pub def mo_velocity (t : Tune) (s : MoState) (i : Intent) (dt : F64) : MoState :=
    let since_press : F64 := if i.jump_pressed then 0.0 else s.since_press + dt in
    let since_ground : F64 := if s.grounded then 0.0 else s.since_ground + dt in
    let v0 : Vec3 := steer t s i dt in
    let jump_now : Bool := since_press <= t.buffer && since_ground <= t.coyote in
    let v1 : Vec3 := if jump_now then vec3 v0.x t.jump_speed v0.z else v0 in
    let jumping1 : Bool := if jump_now then true else s.jumping in
    // A released jump while rising is cut once (a short hop).
    let cut : Bool := jumping1 && Bool.not i.jump_held && v1.y > 0.0 in
    let v2 : Vec3 := if cut then vec3 v1.x (v1.y * t.jump_cut) v1.z else v1 in
    let airborne : Bool := jump_now || Bool.not s.grounded in
    let dash_now : Bool := i.dash_pressed && airborne && Bool.not s.dashed in
    let dir0 : Vec3 := clamp_unit (intent_move i) in
    let dir : Vec3 := if v3_length dir0 > 0.1 then v3_normalize dir0 else s.facing in
    let v3 : Vec3 :=
        if dash_now then vec3 (dir.x * t.dash_speed) (f64_max v2.y t.dash_lift) (dir.z * t.dash_speed) else v2 in
    let vy : F64 :=
        if airborne then f64_max (0.0 - t.max_fall) (v3.y - t.gravity * dt) else 0.0 - 1.0 in
    let vel : Vec3 := vec3 v3.x vy v3.z in
    let jumping2 : Bool := (jumping1 && Bool.not cut && vy > 0.0) && Bool.not dash_now in
    mk vel (s.grounded && Bool.not jump_now)
        (if jump_now then long_ago else since_ground)
        (if jump_now then long_ago else since_press)
        jumping2
        (s.dashed || dash_now)
        (turn t s.facing vel dt)

/// After the move: ground and ceiling contacts.
pub def mo_landed (s : MoState) (sl : Slide) : MoState :=
    let g : Bool := slide_grounded sl in
    let vy : F64 :=
        if g && s.vel.y < 0.0 then 0.0
        else if slide_hit_ceiling sl && s.vel.y > 0.0 then 0.0
        else s.vel.y in
    mk (vec3 s.vel.x vy s.vel.z) g s.since_ground s.since_press (s.jumping && Bool.not g)
       (s.dashed && Bool.not g) s.facing

// ── Moving ──────────────────────────────────────────────────────────

pub def mo_shape : Shape := shape_capsule mo_radius mo_half_height

/// A whole step: velocity, move through `scene` (ignoring `self_e`), land.
pub struct MoStep {
    state : MoState,
    pos : Vec3,
    slide : Slide
}

pub instance Copy MoStep {
    def copy (s : MoStep) : Pair MoStep MoStep := Pair.pair s s
}

pub def step_state (s : MoStep) : MoState := s.state

pub def step_pos (s : MoStep) : Vec3 := s.pos

pub def mo_step (t : Tune) (scene : Scene) (self_e : Option Entity) (s : MoState) (pos : Vec3) (i : Intent)
    (dt : F64) : MoStep :=
    let v : MoState := mo_velocity t s i dt in
    let sl : Slide := move_and_slide scene self_e mo_shape move_config_default pos (v3_scale v.vel dt) s.grounded in
    { state := mo_landed v sl, pos := slide_position sl, slide := sl : MoStep }

/// The rotation about +y that turns +z to `f` (unit, on the ground plane),
/// built from half-angle identities (there is no `atan2`).
pub def yaw_quat (f : Vec3) : Quat :=
    let c : F64 := f64_sqrt (f64_max 0.0 ((1.0 + f.z) * 0.5)) in
    let s0 : F64 := f64_sqrt (f64_max 0.0 ((1.0 - f.z) * 0.5)) in
    let s : F64 := if f.x < 0.0 then 0.0 - s0 else s0 in
    quat 0.0 s 0.0 c

// ── The component and system ────────────────────────────────────────

pub def mo_name : String := "mo.state"

def as_mo (v : Any) : MoState :=
    match v { Any.any x => let s : MoState := x in s }

pub def entity_mo (world : World) (e : Entity) : MoState :=
    match get_component_named world e mo_name {
        Option.some v => as_mo v,
        Option.none => mo_rest
    }

pub def set_mo (world : World) (e : Entity) (s : MoState) : World :=
    insert_component world e mo_name (Any.any s)

/// The Mo entity, if the world has one.
pub def find_mo (world : World) : Option Entity := List.first (query_entities world [mo_name, transform_name] [])

pub def mo_position (world : World) (e : Entity) : Vec3 :=
    match entity_transform world e {
        Option.some t0 => let t : Transform := t0 in t.translation,
        Option.none => v3_zero
    }

/// Place Mo at `p` facing `facing`, keeping scale.
pub def place_mo (world : World) (e : Entity) (p : Vec3) (facing : Vec3) : World :=
    match entity_transform world e {
        Option.some t0 =>
            let t : Transform := t0 in
            insert_component world e transform_name (Any.any (transform_new p (yaw_quat facing) t.scale)),
        Option.none => world
    }

def step_mo (world : World) (e : Entity) : World :=
    let st : MoStep := mo_step tune (collision_scene world) (Option.some e) (entity_mo world e)
                             (mo_position world e) (world_intent world) (time_delta (world_time world)) in
    set_mo (place_mo world e st.pos st.state.facing) e st.state

pub def mo_move (world : World) : World :=
    match find_mo world {
        Option.some e => step_mo world e,
        Option.none => world
    }

pub def mo_system : WorldM Id Unit := WorldM.modify mo_move
