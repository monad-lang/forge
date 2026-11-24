// Mo Venture: the companion's AI.
//
// One Mo is controlled; the other follows. The follower walks toward a
// standing slot near the player, jumps when the ground ahead runs out or a
// step is in the way (the same probes the autopilot uses), and sprints when
// it has fallen far behind. It never presses the ability or swap keys: a
// puzzle that needs an ability needs the player to swap into that hero.
//
// ## Where the slot is
//
// The slot is placed in CAMERA space, not in Mo's facing: `follow_behind`
// units toward the camera and `follow_side` units to the camera's right. Two
// reasons, both about the view:
//
//   - the camera sits behind Mo and looks along the course, so "behind Mo" is
//     the camera->player axis -- a follower put there stands in the middle of
//     the screen, on top of the thing the player is aiming at;
//   - the side offset moves it out of the centre of the frame, low and to one
//     side, where a companion belongs.
//
// The slot is only ever taken where there is ground under it (a short
// downward probe): a slot hanging over a gap is not a place to stand.
//
// ## Why it does not oscillate
//
// Two hysteresis rules, both carried in the `mo.follow` resource:
//
//   - the follower starts walking when the slot is `follow_start` away and
//     keeps walking until it is `follow_stop` away (a dead zone with a gap
//     between the two, so it cannot flip on consecutive frames);
//   - the leash fires only after the stranded condition has held for
//     `leash_delay` frames, and then not again for `leash_cooldown` frames.
//     A player who outruns the follower gets one clean catch-up, not a
//     teleport every frame -- which is what read as the follower jittering.
//
// ## What the leash does
//
// If the follower is left too far behind, too far below, or falls out of the
// level, it is put at the standing slot next to the player, standing on the
// ground found under that slot (never at a guessed height, which used to
// drop it and re-fire the leash on the next frame). That is the whole of its
// pathfinding: it can follow over small gaps, not solve the level.

use forge_core::ecs {World, Spawned, Entity, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_math {Vec3, vec3, v3_add, v3_sub, v3_length, v3_scale, Ray, ray}
use forge_collide {Scene, Hit, raycast, hit_point, layer_all}
use lib::tune {Tune, mo_stand}
use lib::mo {
    Intent, intent, MoState, entity_mo, set_mo, place_mo, mo_position, mo_facing,
    mo_airborne_for, mo_hero, find_mo, find_companion, clear_footing
}
use lib::bot {toward, ground_ahead}

def flat (v : Vec3) : Vec3 := vec3 v.x 0.0 v.z

/// How far the ground probe under a slot looks (a step down or up the level
/// allows; a slot more than this above or below the follower's feet is not
/// "the same place").
pub def slot_probe_drop : F64 := 3.0

// ── The slot ────────────────────────────────────────────────────────

/// The surface height under `at`'s footprint, if there is one within
/// `slot_probe_drop` below `from_y`. This is what makes a slot a place to
/// stand rather than a point in the air.
pub def ground_y_at (sc : Scene) (at : Vec3) (from_y : F64) : Option F64 :=
    let r : Ray := ray (vec3 at.x (from_y + 0.4) at.z) (vec3 0.0 (0.0 - 1.0) 0.0) in
    ground_hit (raycast sc r (slot_probe_drop + 0.4) layer_all)

def ground_hit (h : Option Hit) : Option F64 :=
    match h {
        Option.none => Option.none,
        Option.some x =>
            // No field access on a call result (PLAN.md gap G11): bind first.
            let at : Vec3 := hit_point x in
            Option.some at.y
    }

/// Where the follower should stand, given the player's feet at `player_pos`
/// and the camera's ground-plane basis (`cam_f` forward, `cam_r` right, both
/// unit). Behind toward the camera and to one side; `Option.none` when no
/// candidate has ground under it.
///
/// Candidates run from the full offset down to none at all, so a slot on a
/// narrow ledge next to the player still resolves instead of falling back to
/// the player's own feet (which is the one place the follower must not
/// stand).
pub def follow_slot (t : Tune) (sc : Scene) (player_pos : Vec3) (cam_f : Vec3) (cam_r : Vec3)
    : Option Vec3 :=
    let feet : F64 := player_pos.y - mo_stand in
    let back : Vec3 := v3_scale (flat cam_f) (0.0 - t.follow_behind) in
    let side : Vec3 := v3_scale (flat cam_r) t.follow_side in
    let full : Vec3 := v3_add back side in
    slot_scan sc (vec3 player_pos.x feet player_pos.z) full feet 1.0

/// Try `offset`, then the same offset shrunk toward the player, and stop at
/// the first candidate with ground under it. (`slot_scan` must be defined
/// before `scan_step`, which recurses into it: monad has no forward
/// references.)
#[terminating]
def slot_scan (sc : Scene) (feet_at : Vec3) (offset : Vec3) (feet : F64) (shrink : F64) : Option Vec3 :=
    scan_step sc feet_at offset feet shrink

#[terminating]
def scan_step (sc : Scene) (feet_at : Vec3) (offset : Vec3) (feet : F64) (shrink : F64) : Option Vec3 :=
    if shrink > 0.0
    then
        let p : Vec3 := v3_add feet_at (v3_scale offset shrink) in
        scan_try sc feet_at offset feet shrink p (ground_y_at sc p feet)
    else Option.none

/// The probe's answer, as a binder (`match` takes a binder, not an
/// application: `match f x with` is a parse error).
#[terminating]
def scan_try (sc : Scene) (feet_at : Vec3) (offset : Vec3) (feet : F64) (shrink : F64)
    (p : Vec3) (g : Option F64) : Option Vec3 :=
    match g {
        Option.none => slot_scan sc feet_at offset feet (shrink - 0.25),
        Option.some y => Option.some (vec3 p.x y p.z)
    }

// ── The follow state ────────────────────────────────────────────────

/// What the follower remembers between frames: the slot it is walking to,
/// whether it is currently walking, and how long the leash condition has held
/// plus how long since the leash last fired. `Copy`.
pub struct Follow {
    target : Vec3,
    moving : Bool,
    /// Frames the stranded condition has held without a leash firing.
    stranded : I64,
    /// Frames the leash is still barred for after it fired (0 = ready). It is
    /// a countdown, not a count-up: a fresh session is ready to leash at once,
    /// and a fire starts the cooldown.
    cooldown : I64
}

pub instance Copy Follow {
    def copy (f : Follow) : Pair Follow Follow := Pair.pair f f
}

pub def follow_name : String := "mo.follow"

pub def follow_new (at : Vec3) : Follow :=
    { target := at, moving := false, stranded := 0, cooldown := 0 : Follow }

pub def follow_target_of (f : Follow) : Vec3 := f.target

pub def follow_moving (f : Follow) : Bool := f.moving

def as_follow (v : Any) : Follow :=
    match v { Any.any x => let f : Follow := x in f }

pub def world_follow_opt (world : World) : Option Follow :=
    match List.first (query_entities world [follow_name] []) {
        Option.some e =>
            match get_component_named world e follow_name {
                Option.some v => Option.some (as_follow v),
                Option.none => Option.none
            },
        Option.none => Option.none
    }

pub def world_set_follow (world : World) (f : Follow) : World :=
    match List.first (query_entities world [follow_name] []) {
        Option.some e => insert_component world e follow_name (Any.any f),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair follow_name (Any.any f)] in
            s.world
    }

/// One frame of the follower's memory: re-aim the slot only when it is worth
/// it, and run the latch.
///
/// - **Re-aim** when the follower is not walking and the player has moved
///   `follow_start` off the slot: a slot that follows the player's every
///   twitch makes the follower chase a point that never settles.
/// - **Latch** on at `follow_start`, off at `follow_stop`: the two distances
///   differ, so no frame can both start and stop the walk.
pub def follow_step (t : Tune) (sc : Scene) (f : Follow) (pos : Vec3) (player_pos : Vec3)
    (cam_f : Vec3) (cam_r : Vec3) : Follow :=
    follow_with t (follow_slot t sc player_pos cam_f cam_r) f pos

/// `follow_step`'s body, with the slot as a binder (`match` takes a binder,
/// never an application).
def follow_with (t : Tune) (slot : Option Vec3) (f : Follow) (pos : Vec3) : Follow :=
    match slot {
        Option.none => f,
        Option.some target => follow_aim t f pos target
    }

/// The latch and the re-aim, given the candidate slot `target`:
///
/// - the distance that decides is measured from `pos` (the follower);
/// - the follower starts walking past `follow_start` and stops inside
///   `follow_stop`;
/// - a walker keeps its old slot (the destination must not move under it),
///   and a settled follower adopts the new one.
def follow_aim (t : Tune) (f : Follow) (pos : Vec3) (target : Vec3) : Follow :=
    let d : F64 := v3_length (flat (v3_sub target pos)) in
    let moving : Bool := if f.moving then Bool.not (t.follow_stop > d) else d > t.follow_start in
    let aim : Vec3 := if f.moving then f.target else target in
    let f2 : Follow := { target := aim, moving := moving, stranded := f.stranded,
                         cooldown := f.cooldown : Follow } in
    f2

// ── Intent ──────────────────────────────────────────────────────────

/// What the companion wants this frame: toward its slot (when it is walking),
/// jumping gaps and steps, sprinting when far behind.
pub def follow_intent (t : Tune) (sc : Scene) (s : MoState) (pos : Vec3) (f : Follow) : Intent :=
    let target : Vec3 := f.target in
    let feet : F64 := pos.y - mo_stand in
    let dir : Vec3 := toward pos target in
    let gap : F64 := v3_length (flat (v3_sub target pos)) in
    let moving : Bool := f.moving && gap > 0.05 in
    let edge : Bool := moving && Bool.not (ground_ahead sc pos dir feet) in
    let step_up : Bool := moving && target.y - feet > 0.3 && gap < 2.2 in
    let jump : Bool := moving && s.grounded && (edge || step_up) in
    let sprint : Bool := moving && gap > t.follow_sprint in
    if moving
    then intent dir.x dir.z jump true false sprint
    else intent 0.0 0.0 false false false false

/// The slot for a world that has no follower memory yet (the first frame): a
/// still follower standing where it is, aimed at the player's side.
pub def follow_seed (t : Tune) (sc : Scene) (pos : Vec3) (player_pos : Vec3) (cam_f : Vec3)
    (cam_r : Vec3) : Follow :=
    let at : Vec3 :=
        match follow_slot t sc player_pos cam_f cam_r {
            Option.some p => p,
            Option.none => vec3 pos.x pos.y pos.z
        } in
    follow_new at

// ── The leash ───────────────────────────────────────────────────────

/// Bring the companion back when it is stranded: too far behind, too far
/// below, or under the level. Fires after the condition has held
/// `leash_delay` frames and then not for `leash_cooldown` frames (hysteresis:
/// one catch-up per stranding), and puts the follower *standing on the
/// ground* under its slot rather than at a guessed height.
pub def leash_step (t : Tune) (sc : Scene) (kill_y : F64) (cam_f : Vec3) (cam_r : Vec3)
    (world : World) : World :=
    match find_mo world {
        Option.none => world,
        Option.some p0 =>
            let p : Entity := p0 in
            match find_companion world {
                Option.none => world,
                Option.some c0 => let c : Entity := c0 in leash world p c t sc kill_y cam_f cam_r
            }
    }

def leash (world : World) (p : Entity) (c : Entity) (t : Tune) (sc : Scene) (kill_y : F64)
    (cam_f : Vec3) (cam_r : Vec3) : World :=
    let pp : Vec3 := mo_position world p in
    let cp : Vec3 := mo_position world c in
    let d : F64 := v3_length (flat (v3_sub pp cp)) in
    let below : Bool := pp.y - cp.y > t.leash_height in
    let fallen : Bool := cp.y < kill_y in
    let stranded : Bool := d > t.leash_distance || below || fallen in
    let f0 : Follow := match world_follow_opt world {
        Option.some x => x,
        Option.none => follow_seed t sc cp pp cam_f cam_r
    } in
    // The cooldown ticks down one frame at a time.
    let ready : I64 := if f0.cooldown > 0 then I64.sub f0.cooldown 1 else 0i64 in
    let f : Follow := { target := f0.target, moving := f0.moving, stranded := f0.stranded,
                        cooldown := ready : Follow } in
    if Bool.not stranded
    then
        // Nothing wrong: forget the count, and let the follower walk on.
        let f1 : Follow := { target := f.target, moving := f.moving, stranded := 0,
                             cooldown := f.cooldown : Follow } in
        world_set_follow world (follow_step t sc f1 cp pp cam_f cam_r)
    else if f.cooldown > 0
    then
        // Still cooling down from the last catch-up: keep waiting, and DO
        // NOT reset `stranded`, so the delay is measured from when the
        // follower got into trouble, not from the last fire.
        let f1 : Follow := { target := f.target, moving := f.moving,
                             stranded := I64.add f.stranded 1, cooldown := f.cooldown : Follow } in
        world_set_follow world (follow_step t sc f1 cp pp cam_f cam_r)
    else if t.leash_delay > f.stranded
    then
        // The condition has not held long enough yet.
        let f1 : Follow := { target := f.target, moving := f.moving,
                             stranded := I64.add f.stranded 1, cooldown := f.cooldown : Follow } in
        world_set_follow world (follow_step t sc f1 cp pp cam_f cam_r)
    else
        // Stranded for long enough, and ready: one catch-up.
        let slot : Vec3 := match follow_slot t sc pp cam_f cam_r {
            Option.some s => s,
            // No ground anywhere near the player (a slot over a gap): put the
            // follower at the player's feet rather than at a guessed height.
            Option.none => vec3 pp.x pp.y pp.z
        } in
        let s0 : MoState := entity_mo world c in
        let w1 : World := place_mo world c slot (mo_facing s0) in
        let w2 : World := set_mo w1 c (mo_airborne_for (mo_hero s0)) in
        let w3 : World := clear_footing w2 c in
        world_set_follow w3 { target := slot, moving := false, stranded := 0,
                              cooldown := t.leash_cooldown : Follow }
