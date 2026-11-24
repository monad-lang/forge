// Mo Venture: Mo, the hero.
//
// Mo is a capsule collider driven by forge-collide's kinematic controller.
// Each frame:
//
// 1. an `Intent` (where to run, jump/dash presses) comes from the keyboard
//    or from the autopilot (`bot.mo`);
// 2. `mo_velocity` turns intent into velocity: momentum on the ground and
//    in the air, jump with coyote time, buffering and a short-hop cut, one
//    mid-air jump and one air dash per airtime, gravity;
// 3. `move_and_slide` moves Mo by `velocity * dt` through the level;
// 4. `mo_landed` reads what the move touched (ground, ceiling).
//
// All of it is pure; `mo_system` just reads and writes the world.
//
// Moving platforms carry Mo: a platform that moved this frame records its
// `Carrier` delta, and if Mo stood on it last frame, Mo moves by the same
// delta before its own move. Jumping off keeps the platform's motion.

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {
    World, Entity, Spawned, spawn, insert_component, remove_component, get_component_named
}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math {
    Vec3, vec3, v3_zero, v3_one, v3_add, v3_sub, v3_scale, v3_length, v3_normalize, v3_lerp,
    Quat, quat, Ray, ray, f64_sqrt, f64_max, f64_min, f64_abs
}
use forge_scene {Transform, transform_new, transform_name, entity_transform, find_named}
use forge_animate {Easing, set_tween, tween_scale}
use forge_schedule {world_time, time_delta}
use forge_collide {
    Scene, Shape, Collider, shape_capsule, collision_scene, move_and_slide, MoveConfig, move_config,
    Slide, slide_position, slide_grounded, slide_hit_ceiling, slide_ground,
    Entry, entry_entity, entry_collider, collider_layer, collider_with_layers, collider,
    layer_default, raycast, Hit, hit_entity, hit_normal, scene_entries, same_entity
}
use lib::tune {Tune, tune, mo_radius, mo_half_height, mo_stand}
use lib::hero {hero_xiaozhu, hero_xiaomao, ability_none, ability_spin, ability_slam}

// ── Intent ──────────────────────────────────────────────────────────

/// What the player (or the autopilot) wants this frame. `mx`/`mz` is the
/// run direction in world space (length 0..1). `Copy`.
pub struct Intent {
    mx : F64,
    mz : F64,
    jump_pressed : Bool,
    jump_held : Bool,
    dash_pressed : Bool,
    sprint : Bool,
    ability_pressed : Bool,
    swap_pressed : Bool
}

pub instance Copy Intent {
    def copy (i : Intent) : Pair Intent Intent := Pair.pair i i
}

pub def intent_none : Intent :=
    { mx := 0.0, mz := 0.0, jump_pressed := false, jump_held := false, dash_pressed := false,
      sprint := false, ability_pressed := false, swap_pressed := false : Intent }

pub def intent (mx : F64) (mz : F64) (jump_pressed : Bool) (jump_held : Bool) (dash_pressed : Bool)
    (sprint : Bool) : Intent :=
    { mx := mx, mz := mz, jump_pressed := jump_pressed, jump_held := jump_held,
      dash_pressed := dash_pressed, sprint := sprint, ability_pressed := false,
      swap_pressed := false : Intent }

/// `i` with this frame's ability and swap presses (the `X` and `C` keys).
pub def intent_ext (i : Intent) (ability : Bool) (swap : Bool) : Intent :=
    { mx := i.mx, mz := i.mz, jump_pressed := i.jump_pressed, jump_held := i.jump_held,
      dash_pressed := i.dash_pressed, sprint := i.sprint, ability_pressed := ability,
      swap_pressed := swap : Intent }

pub def intent_ability (i : Intent) (ability : Bool) : Intent := intent_ext i ability i.swap_pressed

pub def intent_swap (i : Intent) (swap : Bool) : Intent := intent_ext i i.ability_pressed swap

pub def intent_move (i : Intent) : Vec3 := vec3 i.mx 0.0 i.mz

pub def intent_ability_pressed (i : Intent) : Bool := i.ability_pressed

pub def intent_swapped (i : Intent) : Bool := i.swap_pressed

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
/// is long past). `facing` is a unit vector on the ground plane.
/// `air_used` counts mid-air jumps this airtime. `Copy`.
pub struct MoState {
    vel : Vec3,
    grounded : Bool,
    since_ground : F64,
    since_press : F64,
    since_jump : F64,
    jumping : Bool,
    dashed : Bool,
    air_used : I64,
    facing : Vec3,
    hero : I64,
    climbing : Bool,
    ability : I64,
    ability_age : F64
}

pub instance Copy MoState {
    def copy (s : MoState) : Pair MoState MoState := Pair.pair s s
}

pub def long_ago : F64 := 100.0

/// At rest, on the ground, facing -z (into the level), as Xiaozhu.
pub def mo_rest : MoState := mo_rest_for hero_xiaozhu

/// `mo_rest` for hero `h`.
pub def mo_rest_for (h : I64) : MoState :=
    { vel := v3_zero, grounded := true, since_ground := 0.0, since_press := long_ago, since_jump := long_ago,
      jumping := false, dashed := false, air_used := 0, facing := vec3 0.0 0.0 (0.0 - 1.0),
      hero := h, climbing := false, ability := ability_none, ability_age := 0.0 : MoState }

/// Just left the ground (this frame), not having jumped.
pub def mo_airborne : MoState := mo_airborne_for hero_xiaozhu

/// `mo_airborne` for hero `h`.
pub def mo_airborne_for (h : I64) : MoState :=
    { vel := v3_zero, grounded := false, since_ground := 0.0, since_press := long_ago, since_jump := long_ago,
      jumping := false, dashed := false, air_used := 0, facing := vec3 0.0 0.0 (0.0 - 1.0),
      hero := h, climbing := false, ability := ability_none, ability_age := 0.0 : MoState }

pub def mo_vel (s : MoState) : Vec3 := s.vel

pub def mo_grounded (s : MoState) : Bool := s.grounded

pub def mo_dashed (s : MoState) : Bool := s.dashed

pub def mo_facing (s : MoState) : Vec3 := s.facing

pub def mo_air_used (s : MoState) : I64 := s.air_used

pub def mo_hero (s : MoState) : I64 := s.hero

pub def mo_with_hero (s : MoState) (h : I64) : MoState :=
    mk s.vel s.grounded s.since_ground s.since_press s.since_jump s.jumping s.dashed s.air_used
       s.facing h s.climbing s.ability s.ability_age

pub def mo_climbing (s : MoState) : Bool := s.climbing

pub def mo_with_climb (s : MoState) (b : Bool) : MoState :=
    mk s.vel s.grounded s.since_ground s.since_press s.since_jump s.jumping s.dashed s.air_used
       s.facing s.hero b s.ability s.ability_age

pub def mo_ability (s : MoState) : I64 := s.ability

pub def mo_ability_age (s : MoState) : F64 := s.ability_age

pub def mo_with_ability (s : MoState) (a : I64) (age : F64) : MoState :=
    mk s.vel s.grounded s.since_ground s.since_press s.since_jump s.jumping s.dashed s.air_used
       s.facing s.hero s.climbing a age

def mk (vel : Vec3) (grounded : Bool) (since_ground : F64) (since_press : F64) (since_jump : F64)
    (jumping : Bool) (dashed : Bool) (air_used : I64) (facing : Vec3) (hero : I64) (climbing : Bool)
    (ability : I64) (ability_age : F64) : MoState :=
    { vel := vel, grounded := grounded, since_ground := since_ground, since_press := since_press,
      since_jump := since_jump, jumping := jumping, dashed := dashed, air_used := air_used,
      facing := facing, hero := hero, climbing := climbing, ability := ability,
      ability_age := ability_age : MoState }

/// `s` with its ground contact replaced (a co-op guest is told where the
/// host's hero stands, including whether it is on the ground).
pub def mo_with_grounded (s : MoState) (g : Bool) : MoState :=
    mk s.vel g s.since_ground s.since_press s.since_jump s.jumping s.dashed s.air_used
       s.facing s.hero s.climbing s.ability s.ability_age

pub def mo_with_vel (s : MoState) (v : Vec3) : MoState :=
    mk v s.grounded s.since_ground s.since_press s.since_jump s.jumping s.dashed s.air_used
       s.facing s.hero s.climbing s.ability s.ability_age

/// `s` with its mid-air jumps for this airtime marked used (tests and the
/// autopilot's reach model).
pub def mo_with_air_used (s : MoState) (n : I64) : MoState :=
    mk s.vel s.grounded s.since_ground s.since_press s.since_jump s.jumping s.dashed n
       s.facing s.hero s.climbing s.ability s.ability_age

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
///
/// Jumps: a press counts for `buffer` seconds and starts a ground jump while
/// Mo is grounded or left the ground under `coyote` seconds ago. Otherwise,
/// in the air, a fresh press spends one of `air_jumps` (the rising speed is
/// replaced, not added to). Releasing Space while rising cuts the rise once
/// (a short hop), but only after `min_hop` seconds of rise: a tap that goes
/// down and up inside one frame, or a buffered press released before the
/// landing, used to be cut on the jump's first frame into a hop so small it
/// looked like a dropped input.
pub def mo_velocity (t : Tune) (s : MoState) (i : Intent) (dt : F64) : MoState :=
    let since_press : F64 := if i.jump_pressed then 0.0 else s.since_press + dt in
    let since_ground : F64 := if s.grounded then 0.0 else s.since_ground + dt in
    // The ability key: Xiaozhu slams from the air, Xiaomao spins anywhere.
    // A slam is kept until the landing frame (rules breaks boxes there) or
    // till `slam_timeout`; a spin runs its own timer.
    let age0 : F64 := if s.ability == ability_none then 0.0 else s.ability_age + dt in
    let press : Bool := i.ability_pressed && s.ability == ability_none in
    let slam_start : Bool := press && s.hero == hero_xiaozhu && Bool.not s.grounded && Bool.not s.climbing in
    let spin_start : Bool := press && s.hero == hero_xiaomao in
    let ability1 : I64 :=
        if slam_start then ability_slam else if spin_start then ability_spin else s.ability in
    let age1 : F64 := if slam_start || spin_start then 0.0 else age0 in
    let spinning : Bool := ability1 == ability_spin && age1 <= t.spin_time in
    let slamming : Bool := ability1 == ability_slam && age1 <= t.slam_timeout in
    let ability2 : I64 :=
        if ability1 == ability_spin then (if spinning then ability_spin else ability_none)
        else if ability1 == ability_slam then (if slamming then ability_slam else ability_none)
        else ability_none in
    let v0 : Vec3 := steer t s i dt in
    let jump_now : Bool := since_press <= t.buffer && since_ground <= t.coyote && Bool.not s.climbing in
    let air_jump : Bool := Bool.not jump_now && i.jump_pressed && Bool.not s.grounded
        && s.air_used < t.air_jumps && Bool.not s.climbing in
    let launched : Bool := jump_now || air_jump in
    let v1 : Vec3 :=
        if jump_now then vec3 v0.x t.jump_speed v0.z
        else if air_jump then vec3 v0.x t.air_jump_speed v0.z
        else v0 in
    let since_jump : F64 := if launched then 0.0 else s.since_jump + dt in
    let jumping1 : Bool := if launched then true else s.jumping in
    // A released jump while rising is cut once (a short hop), never before
    // `min_hop` seconds of rise.
    let cut : Bool := jumping1 && Bool.not i.jump_held && v1.y > 0.0 && since_jump >= t.min_hop in
    let v2 : Vec3 := if cut then vec3 v1.x (v1.y * t.jump_cut) v1.z else v1 in
    let airborne : Bool := launched || Bool.not s.grounded in
    let dash_now : Bool := i.dash_pressed && airborne && Bool.not s.dashed && Bool.not s.climbing in
    let dir0 : Vec3 := clamp_unit (intent_move i) in
    let dir : Vec3 := if v3_length dir0 > 0.1 then v3_normalize dir0 else s.facing in
    let v3 : Vec3 :=
        if dash_now then vec3 (dir.x * t.dash_speed) (f64_max v2.y t.dash_lift) (dir.z * t.dash_speed) else v2 in
    let vy : F64 :=
        if s.climbing then t.climb_speed
        else if ability2 == ability_slam && airborne then 0.0 - t.slam_speed
        else if airborne then f64_max (0.0 - t.max_fall) (v3.y - t.gravity * dt)
        else 0.0 - 1.0 in
    let vel : Vec3 := vec3 v3.x vy v3.z in
    let jumping2 : Bool := (jumping1 && Bool.not cut && vy > 0.0) && Bool.not dash_now in
    mk vel (s.grounded && Bool.not jump_now)
        (if jump_now then long_ago else since_ground)
        (if launched then long_ago else since_press)
        since_jump
        jumping2
        (s.dashed || dash_now)
        (if air_jump then s.air_used + 1 else s.air_used)
        (turn t s.facing vel dt)
        s.hero s.climbing ability2 age1

/// After the move: ground and ceiling contacts. Landing gives back the
/// dash and the mid-air jumps.
pub def mo_landed (s : MoState) (sl : Slide) : MoState :=
    let g : Bool := slide_grounded sl in
    let vy : F64 :=
        if g && s.vel.y < 0.0 then 0.0
        else if slide_hit_ceiling sl && s.vel.y > 0.0 then 0.0
        else s.vel.y in
    mk (vec3 s.vel.x vy s.vel.z) g s.since_ground s.since_press s.since_jump (s.jumping && Bool.not g)
       (s.dashed && Bool.not g) (if g then 0 else s.air_used) s.facing
       s.hero (s.climbing && Bool.not g) s.ability s.ability_age

// ── Moving ──────────────────────────────────────────────────────────

pub def mo_shape : Shape := shape_capsule mo_radius mo_half_height

// ── Layers and climbing ─────────────────────────────────────────────

/// World geometry (platforms, boxes, gates).
pub def layer_world : I64 := layer_default

/// A wall Xiaomao can climb.
pub def layer_climb : I64 := 2

/// The characters themselves; they do not block each other.
pub def layer_mo : I64 := 4

/// What a character's move collides with.
pub def mo_move_mask : I64 := layer_world + layer_climb

/// The move configuration every character uses.
pub def mo_move_config : MoveConfig := move_config 0.01 0.3 0.2 0.7 mo_move_mask

/// A collider for a character's capsule, on the characters' layer.
pub def mo_move_layers (shape : Shape) : Collider :=
    collider_with_layers (collider shape) layer_mo mo_move_mask

/// The direction the intent pushes, normalized, or zero below 0.15.
def climb_dir (i : Intent) : Vec3 :=
    let m : Vec3 := flat (intent_move i) in
    let l : F64 := v3_length m in
    if l > 0.15 then v3_scale m (1.0 / l) else v3_zero

/// The layer of the collider `e` has in `scene` (0 when it has none).
#[terminating]
def entry_layer (es : List Entry) (e : Entity) : I64 :=
    match es {
        List.empty => 0,
        List.cons x rest =>
            if same_entity (entry_entity x) e then collider_layer (entry_collider x) else entry_layer rest e
    }

/// Is a climbable wall within reach along `dir`? A short horizontal ray at
/// FOOT height (just above the floor), accepting a near-vertical wall on
/// the climb layer. Foot height matters: it keeps the grip up to the very
/// top of a wall, so climbing a flush ledge carries Mo over the lip
/// instead of stopping a body-height short.
/// (The controller reports `hit_wall` but no wall normal, and never climbs.)
pub def climbing_wall (scene : Scene) (pos : Vec3) (dir : Vec3) : Bool :=
    if v3_length dir < 0.5 then false
    else
        let eye : Vec3 := vec3 pos.x (pos.y - (mo_stand - 0.05)) pos.z in
        match raycast scene (ray eye dir) (mo_radius + 0.35) mo_move_mask {
            Option.none => false,
            Option.some h0 =>
                let h : Hit := h0 in
                let n : Vec3 := hit_normal h in
                let wall : Bool := f64_abs n.y < 0.35 in
                let layer : I64 := entry_layer (scene_entries scene) (hit_entity h) in
                wall && Bool.not (I64.and layer layer_climb == 0)
        }

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
    let dir : Vec3 := climb_dir i in
    let climbing : Bool := s.hero == hero_xiaomao && climbing_wall scene pos dir in
    let s1 : MoState := mo_with_climb s climbing in
    let v : MoState := mo_velocity t s1 i dt in
    let sl : Slide := move_and_slide scene self_e mo_shape mo_move_config pos (v3_scale v.vel dt) s.grounded in
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

// ── Roles: the controlled Mo and the companion ──────────────────────

/// Marker on the Mo the player controls.
pub def player_name : String := "mo.player"

/// Marker on the Mo that follows.
pub def companion_name : String := "mo.companion"

pub def has_marker (world : World) (e : Entity) (name : String) : Bool :=
    match get_component_named world e name {
        Option.some _ => true,
        Option.none => false
    }

pub def is_player (world : World) (e : Entity) : Bool := has_marker world e player_name

/// The controlled Mo: the player-marked one, else the first Mo (single-Mo
/// worlds and the older tests).
pub def find_mo (world : World) : Option Entity :=
    match List.first (query_entities world [mo_name, transform_name, player_name] []) {
        Option.some e => Option.some e,
        Option.none => List.first (query_entities world [mo_name, transform_name] [])
    }

/// The following Mo, if any.
pub def find_companion (world : World) : Option Entity :=
    List.first (query_entities world [mo_name, transform_name, companion_name] [])

/// Swap which Mo the player controls. Both keep their looks, positions and
/// state; only the role markers and a running ability change.
def swap_roles (world : World) (p : Entity) (c : Entity) : World :=
    let w1 : World := remove_component (remove_component world p player_name) c companion_name in
    let w2 : World := insert_component (insert_component w1 p companion_name (Any.any true)) c player_name (Any.any true) in
    let w3 : World := set_mo w2 p (mo_with_ability (entity_mo w2 p) ability_none 0.0) in
    set_mo w3 c (mo_with_ability (entity_mo w3 c) ability_none 0.0)

pub def mo_swap (world : World) : World :=
    match find_mo world {
        Option.none => world,
        Option.some p0 =>
            let p : Entity := p0 in
            match find_companion world {
                Option.none => world,
                Option.some c0 => let c : Entity := c0 in swap_roles world p c
            }
    }

/// The companion's intent for this frame (the follow AI writes it).
pub def follow_intent_name : String := "mo.intent.follow"

pub def world_follow_intent (world : World) : Intent :=
    match List.first (query_entities world [follow_intent_name] []) {
        Option.some e =>
            match get_component_named world e follow_intent_name {
                Option.some v => as_intent v,
                Option.none => intent_none
            },
        Option.none => intent_none
    }

pub def world_set_follow_intent (world : World) (i : Intent) : World :=
    match List.first (query_entities world [follow_intent_name] []) {
        Option.some e => insert_component world e follow_intent_name (Any.any i),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair follow_intent_name (Any.any i)] in
            s.world
    }

/// Forget what `e` stands on (after a leash teleport).
pub def clear_footing (world : World) (e : Entity) : World := set_footing world e Option.none

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

// ── Moving platforms ────────────────────────────────────────────────

/// How far a moving platform moved this frame. `Copy`.
#[derive Copy Clone]
pub struct Carrier {
    last : Vec3,
    delta : Vec3
}

pub def carrier_name : String := "mo.carrier"

/// A platform that starts at `p`, not yet moved.
pub def carrier_at (p : Vec3) : Carrier := { last := p, delta := v3_zero : Carrier }

def as_carrier (v : Any) : Carrier :=
    match v { Any.any x => let c : Carrier := x in c }

/// `e`'s move this frame (zero if it is no carrier).
pub def carrier_delta (world : World) (e : Entity) : Vec3 :=
    match get_component_named world e carrier_name {
        Option.some v => let c : Carrier := as_carrier v in c.delta,
        Option.none => v3_zero
    }

def update_carrier (world : World) (e : Entity) : World :=
    match get_component_named world e carrier_name {
        Option.some v =>
            let c : Carrier := as_carrier v in
            let p : Vec3 := mo_position world e in
            insert_component world e carrier_name (Any.any { last := p, delta := v3_sub p c.last : Carrier }),
        Option.none => world
    }

#[terminating]
def update_carriers (world : World) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest => update_carriers (update_carrier world e) rest
    }

/// After the animators moved the platforms: each carrier's delta.
pub def carriers_step (world : World) : World :=
    update_carriers world (query_entities world [carrier_name, transform_name] [])

/// What Mo stood on at the end of last frame. `Copy`.
#[derive Copy Clone]
struct Footing {
    on : Bool,
    e : Entity
}

def footing_name : String := "mo.footing"

def as_footing (v : Any) : Footing :=
    match v { Any.any x => let f : Footing := x in f }

/// The carrier delta under Mo (`e`), from what it stood on last frame.
def carried (world : World) (e : Entity) : Vec3 :=
    match get_component_named world e footing_name {
        Option.some v =>
            let f : Footing := as_footing v in
            if f.on then carrier_delta world f.e else v3_zero,
        Option.none => v3_zero
    }

def set_footing (world : World) (e : Entity) (g : Option Entity) : World :=
    match g {
        Option.some x => insert_component world e footing_name (Any.any { on := true, e := x : Footing }),
        Option.none => insert_component world e footing_name (Any.any { on := false, e := e : Footing })
    }

// ── Squash and stretch ──────────────────────────────────────────────

/// The name of Mo's body part (the one that squashes).
pub def body_name : String := "body"

def squash (world : World) (e : Entity) (from : Vec3) (seconds : F64) : World :=
    match find_named world e body_name {
        Option.some b => set_tween world b (tween_scale from v3_one seconds Easing.quad_out),
        Option.none => world
    }

/// Stretch on take-off, squash on landing.
def juice (world : World) (e : Entity) (before : MoState) (after : MoState) : World :=
    if before.grounded && Bool.not after.grounded && after.vel.y > 0.0
    then squash world e (vec3 0.8 1.25 0.8) 0.25
    else if Bool.not before.grounded && after.grounded
    then squash world e (vec3 1.25 0.75 1.25) 0.2
    else world

// ── The step ────────────────────────────────────────────────────────

/// `s` with the carrier's motion `carry` (over `dt`) added on take-off.
def keep_momentum (before : MoState) (s : MoState) (carry : Vec3) (dt : F64) : MoState :=
    if before.grounded && Bool.not s.grounded && dt > 0.0
    then mo_with_vel s (v3_add s.vel (vec3 (carry.x / dt) 0.0 (carry.z / dt)))
    else s

/// The companion's intent override, as a world component: a co-op guest
/// writes it and `intent_for` reads it. Absent in single-player, which is why
/// the follow AI is unchanged there (`lib::coop` owns the type and the write).
pub def guest_intent_name : String := "mo.coop.guest"

def as_guest_intent (v : Any) : Option Intent :=
    match v { Any.any x => let i : Option Intent := x in i }

/// The guest's intent, when a co-op guest is driving the companion.
pub def world_guest_intent (world : World) : Option Intent :=
    match List.first (query_entities world [guest_intent_name] []) {
        Option.some e =>
            match get_component_named world e guest_intent_name {
                Option.some v => as_guest_intent v,
                Option.none => Option.none
            },
        Option.none => Option.none
    }

/// The intent that drives `e`: the player's, the companion's, or (for an
/// unmarked Mo in an older world) the player's.
///
/// A co-op guest replaces the companion's follow AI: when the guest has
/// written an intent, it wins over `follow_intent`. With no guest in the world
/// this is exactly the single-player rule, so every existing playthrough is
/// unchanged.
def intent_for (world : World) (e : Entity) : Intent :=
    if has_marker world e companion_name
    then companion_intent world
    else world_intent world

/// The companion's intent: the guest's when there is one, the follow AI
/// otherwise.
def companion_intent (world : World) : Intent :=
    match world_guest_intent world {
        Option.some i => i,
        Option.none => world_follow_intent world
    }

def step_mo (world : World) (e : Entity) : World :=
    let dt : F64 := time_delta (world_time world) in
    let s0 : MoState := entity_mo world e in
    let carry : Vec3 := if s0.grounded then carried world e else v3_zero in
    let st : MoStep := mo_step tune (collision_scene world) (Option.some e) s0
                             (v3_add (mo_position world e) carry) (intent_for world e) dt in
    let s1 : MoState := keep_momentum s0 st.state carry dt in
    let w1 : World := set_footing (set_mo (place_mo world e st.pos s1.facing) e s1) e (slide_ground st.slide) in
    juice w1 e s0 s1

#[terminating]
def step_all (world : World) (es : List Entity) : World :=
    match es {
        List.empty => world,
        List.cons e rest => step_all (step_mo world e) rest
    }

/// Advance every Mo (the player and the companion) one step.
pub def mo_move (world : World) : World :=
    step_all world (query_entities world [mo_name, transform_name] [])

pub def mo_system : WorldM Id Unit := WorldM.modify mo_move
