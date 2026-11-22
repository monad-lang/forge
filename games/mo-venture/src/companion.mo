// Mo Venture: the companion's AI.
//
// One Mo is controlled; the other follows. The follower walks toward a spot
// just behind the player, jumps when the ground ahead runs out or a step is
// in the way (the same probes the autopilot uses), and sprints when it has
// fallen behind. It never presses the ability or swap keys: a puzzle that
// needs an ability needs the player to swap into that hero.
//
// If the follower is left too far behind, too far below, or falls out of the
// level, it is brought back to the player's side (`leash_step`). That is the
// whole of its pathfinding: it can follow over small gaps, not solve the
// level.

use forge_core::ecs {World, Entity}
use forge_math {Vec3, vec3, v3_add, v3_sub, v3_length, v3_scale}
use forge_collide {Scene}
use lib::tune {Tune, mo_stand}
use lib::mo {
    Intent, intent, MoState, entity_mo, set_mo, place_mo, mo_position, mo_facing,
    mo_airborne_for, mo_hero, find_mo, find_companion, clear_footing
}
use lib::bot {toward, ground_ahead, ground_at}

def flat (v : Vec3) : Vec3 := vec3 v.x 0.0 v.z

/// The spot on the ground just behind the player, or the player's own feet
/// when there is no ground there (a ledge, a gap).
def follow_target (sc : Scene) (player_pos : Vec3) (player_facing : Vec3) : Vec3 :=
    let behind : Vec3 := vec3 (0.0 - player_facing.x) 0.0 (0.0 - player_facing.z) in
    let feet : F64 := player_pos.y - mo_stand in
    let p : Vec3 := vec3 (player_pos.x + behind.x * follow_gap) feet (player_pos.z + behind.z * follow_gap) in
    if ground_at sc p then p else vec3 player_pos.x feet player_pos.z

/// How far behind the player the follower aims (in units).
def follow_gap : F64 := 1.6

/// What the companion wants this frame: toward the player's back, jumping
/// gaps and steps, sprinting when far away.
pub def follow_intent (t : Tune) (_hero : I64) (sc : Scene) (s : MoState) (pos : Vec3)
    (player_pos : Vec3) (player_facing : Vec3) : Intent :=
    let target : Vec3 := follow_target sc player_pos player_facing in
    let feet : F64 := pos.y - mo_stand in
    let dir : Vec3 := toward pos target in
    let gap : F64 := v3_length (flat (v3_sub target pos)) in
    let moving : Bool := gap > 0.6 in
    let edge : Bool := moving && Bool.not (ground_ahead sc pos dir feet) in
    let step_up : Bool := target.y - feet > 0.3 && gap < 2.2 in
    let jump : Bool := moving && s.grounded && (edge || step_up) in
    let sprint : Bool := gap > t.follow_sprint in
    intent dir.x dir.z jump true false sprint

/// Bring the companion back to the player when it is stranded: too far
/// behind, too far below, or under the level.
pub def leash_step (t : Tune) (kill_y : F64) (world : World) : World :=
    match find_mo world {
        Option.none => world,
        Option.some p0 =>
            let p : Entity := p0 in
            match find_companion world {
                Option.none => world,
                Option.some c0 => let c : Entity := c0 in leash world p c t kill_y
            }
    }

def leash (world : World) (p : Entity) (c : Entity) (t : Tune) (kill_y : F64) : World :=
    let pp : Vec3 := mo_position world p in
    let cp : Vec3 := mo_position world c in
    let d : F64 := v3_length (flat (v3_sub pp cp)) in
    let below : Bool := pp.y - cp.y > t.leash_height in
    let fallen : Bool := cp.y < kill_y in
    if d > t.leash_distance || below || fallen
    then
        let s0 : MoState := entity_mo world c in
        let ps : MoState := entity_mo world p in
        let back : Vec3 := v3_scale (flat (mo_facing ps)) (0.0 - t.follow_behind) in
        let w1 : World := place_mo world c (v3_add pp back) (mo_facing s0) in
        let w2 : World := set_mo w1 c (mo_airborne_for (mo_hero s0)) in
        clear_footing w2 c
    else world
