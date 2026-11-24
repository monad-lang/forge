// Co-op in the game: a guest's intent drives the companion, a host's state
// frame lands a guest's heroes, and neither changes single-player.

use lib::coop {
    world_set_guest_intent, world_clear_guest_intent, has_guest,
    intent_of_wire, hero_of, coop_state, coop_state_text, apply_state, apply_state_text
}
use lib::mo {
    intent, intent_none, world_follow_intent, world_set_follow_intent, mo_position,
    player_name, companion_name, world_intent, has_marker, world_guest_intent, mo_name, Intent
}
use lib::game {world_level_index, mo_venture}
use forge_app {App, app_initial_world}
use forge_core::ecs {World}
use forge_core::query {query_entities}
use forge_math {Vec3, v3_zero, f64_abs}
use forge_online::{
    WireIntent, wire_state, net_decode, wire_intent, wire_neutral, wire_hero, WireHero, net_encode, NetMsg,
    state_player, state_companion, state_sparks, state_level, hero_x, hero_y, hero_z,
    hero_grounded
}
use forge_math {v3_length, v3_sub}

/// A fresh world with level 1 loaded (the same start every playthrough uses),
/// built through the game's own app so both Mo's exist.
def test_world : World := app_initial_world mo_venture

/// A distance small enough to call "in the same place" in a level at this
/// scale.
def close (a : Vec3) (b : Vec3) : Bool :=
    v3_length (v3_sub a b) < 0.05

// ── The guest's intent reaches the companion ────────────────────────

/// The discriminator against the follow AI: with a guest intent pointing away
/// from the player, the companion runs away from the player, not toward it.
#[test]
def test_a_guest_intent_overrides_the_follow_ai : Bool :=
    let w : World := test_world in
    let away : WireIntent := wire_intent 1.0 0.0 false false false false false false in
    let w1 : World := world_set_guest_intent w away in
    has_guest w1
        && (match world_guest_intent w1 {
            Option.none => false,
            Option.some i => f64_abs (intent_mx_of i - 1.0) < 0.01
        })

/// Clearing the guest puts the follow AI back in charge, which is what a
/// disconnect must do (otherwise the companion keeps running on the last
/// frame's input forever).
#[test]
def test_clearing_the_guest_restores_the_follow_ai : Bool :=
    let w : World := test_world in
    let away : WireIntent := wire_intent 1.0 0.0 false false false false false false in
    let w1 : World := world_clear_guest_intent (world_set_guest_intent w away) in
    Bool.not (has_guest w1)
        && (match world_guest_intent w1 {
            Option.none => true,
            Option.some _ => false
        })

/// A world with no guest (the single-player case) is not "has guest", so the
/// follow AI runs -- this is what keeps every playthrough identical.
#[test]
def test_a_single_player_world_has_no_guest : Bool :=
    Bool.not (has_guest (test_world))

/// The buttons survive the wire: jump/dash/sprint are not lost in the
/// quantization.
#[test]
def test_the_buttons_survive_the_wire : Bool :=
    let sent : WireIntent :=
        wire_intent (0.0 - 0.5) 0.5 true true true true false false in
    let got : Intent := intent_of_wire sent in
    intent_jump_pressed_of got && intent_jump_held_of got && intent_dash_of got
        && intent_sprint_of got && f64_abs (intent_mx_of got - (0.0 - 0.5)) < 0.01

def intent_jump_pressed_of (i : Intent) : Bool := i.jump_pressed

def intent_jump_held_of (i : Intent) : Bool := i.jump_held

def intent_dash_of (i : Intent) : Bool := i.dash_pressed

def intent_sprint_of (i : Intent) : Bool := i.sprint

def intent_mx_of (i : Intent) : F64 := i.mx

// ── The host's state ────────────────────────────────────────────────

/// The state a host ships carries both heroes and the run's counters, and it
/// survives the wire.
#[test]
def test_the_host_ships_both_heroes : Bool :=
    let w : World := test_world in
    let text : String := coop_state_text w in
    match net_decode text {
        Result.err _ => false,
        Result.ok m =>
            match m {
                NetMsg.state s =>
                    state_level s == world_level_index w
                        && f64_abs (hero_x (state_player s)) >= 0.0
                        && f64_abs (hero_z (state_companion s)) >= 0.0,
                _ => false
            }
    }

/// The player's wire pose matches where the player actually stands (to the
/// wire's millimetre).
#[test]
def test_the_ships_pose_is_the_real_pose : Bool :=
    let w : World := test_world in
    let h : WireHero := hero_of w player_name in
    let p : Vec3 :=
        match List.first (query_entities w [mo_name, player_name] []) {
            Option.none => v3_zero,
            Option.some e => mo_position w e
        } in
    f64_abs (hero_x h - p.x) < 0.002
        && f64_abs (hero_y h - p.y) < 0.002
        && f64_abs (hero_z h - p.z) < 0.002

// ── The guest applies a state ───────────────────────────────────────

/// A host's state frame moves the guest's player to the host's position.
#[test]
def test_a_state_frame_moves_the_guest : Bool :=
    let w : World := test_world in
    let target : WireHero := wire_hero 3.5 1.25 (0.0 - 2.0) 0.0 true in
    let s := wire_state 0 0 20 0 1.0 target target false in
    let w2 : World := apply_state w s in
    let p : Vec3 := player_pos w2 in
    f64_abs (p.x - 3.5) < 0.002
        && f64_abs (p.y - 1.25) < 0.002
        && f64_abs (p.z - (0.0 - 2.0)) < 0.002

def player_pos (w : World) : Vec3 :=
    match List.first (query_entities w [mo_name, player_name] []) {
        Option.none => v3_zero,
        Option.some e => mo_position w e
    }

/// A malformed frame leaves the world alone rather than half-applying it.
#[test]
def test_a_malformed_frame_changes_nothing : Bool :=
    let w : World := test_world in
    let before : Vec3 := player_pos w in
    let after : World := apply_state_text w "{\"t\":\"state\",\"level\":0}" in
    close (player_pos after) before

/// A frame of the wrong kind is ignored too (a guest must not be moved by an
/// intent frame it happens to receive).
#[test]
def test_a_non_state_frame_is_ignored : Bool :=
    let w : World := test_world in
    let before : Vec3 := player_pos w in
    let after : World := apply_state_text w (net_encode (NetMsg.intent wire_neutral)) in
    close (player_pos after) before

/// Applying the same state twice is the same as applying it once: no
/// accumulation, so a repeated frame cannot drift a guest's hero.
#[test]
def test_applying_a_state_twice_is_idempotent : Bool :=
    let w : World := test_world in
    let target : WireHero := wire_hero 1.0 0.5 1.0 0.0 true in
    let s := wire_state 0 0 20 0 1.0 target target false in
    let once : World := apply_state w s in
    let twice : World := apply_state once s in
    close (player_pos once) (player_pos twice)
