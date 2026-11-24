// Co-op in the game: a guest's intent for the companion, and the state the
// host ships to that guest.
//
// The wire types are `forge_online::net` (pure, tested). This module is the
// game's half: where a remote intent is stored in the world, how it replaces
// the follow AI, and how the visible state is read out of the world.
//
// ## The one rule
//
// With a guest present, the companion is driven by **the guest** and not by
// the follow AI. Everything else about the companion (leash, jump, dash) is
// unchanged: the guest's intent goes in exactly where `follow_intent` did, so
// a guest that wanders off is still brought back and a guest that presses
// jump still jumps.
//
// With no guest, nothing here runs and the game is the single-player game:
// all the existing playthroughs pin that.

use forge_online::{
    WireIntent, WireState, WireHero, NetMsg, net_decode, net_encode, wire_state, wire_hero, wire_neutral,
    wire_intent,
    intent_mx, intent_mz, intent_jump_pressed, intent_jump_held, intent_dash_pressed,
    intent_sprint, intent_ability_pressed, intent_swap_pressed,
    state_level, state_sparks, state_total, state_falls, state_seconds, state_player,
    state_companion, state_won, hero_x, hero_y, hero_z, hero_yaw, hero_grounded
}
use lib::mo {
    Intent, intent, intent_ext, world_follow_intent, world_intent,
    intent_name, mo_name, companion_name, player_name, mo_facing,
    MoState, entity_mo, set_mo, place_mo, mo_position, has_marker, mo_with_grounded,
    guest_intent_name, world_guest_intent, intent_move
}
use lib::rules {
    GameState, world_game_opt, game_new, game_sparks, game_total, game_falls, game_time, game_won
}
use lib::game {world_level, world_level_index, view_orbit}
use forge_core::ecs {
    World, Entity, spawn, get_component_named, insert_component, Spawned
}
use forge_core::query {query_entities}
use forge_math {Vec3, v3_zero, vec3, f64_abs, f64_sqrt, v3_add, v3_scale}
use forge_app {
    Input, CoopHooks, coop_hooks, orbit_forward, orbit_right,
    input_key_held, input_key_pressed, input_axis, world_input
}
use lib::controls {keys_intent}

/// The guest's intent lives in the component `mo.mo` reads
/// (`mo.coop.guest`); this module converts the wire form to the game's
/// `Intent` and writes it there.


// ── The guest's intent ──────────────────────────────────────────────

/// Write a frame of the guest's input into the world, in the game's own
/// `Intent` form (which is what `mo.mo`'s `intent_for` reads).
pub def world_set_guest_intent (world : World) (i : WireIntent) : World :=
    let game_intent : Intent := intent_of_wire i in
    match List.first (query_entities world [guest_intent_name] []) {
        Option.some e => insert_component world e guest_intent_name (Any.any (Option.some game_intent)),
        Option.none =>
            let s : Spawned :=
                spawn world [Pair.pair guest_intent_name (Any.any (Option.some game_intent))] in
            s.world
    }

/// Forget the guest (a leave, or a guest that went quiet): the companion goes
/// back to the follow AI. The component stays, holding `Option.none`, so the
/// cost of leaving is not a component removal.
pub def world_clear_guest_intent (world : World) : World :=
    let none_intent : Option Intent := Option.none in
    match List.first (query_entities world [guest_intent_name] []) {
        Option.some e => insert_component world e guest_intent_name (Any.any none_intent),
        Option.none => world
    }

/// Is a guest driving the companion right now?
pub def has_guest (world : World) : Bool :=
    match world_guest_intent world {
        Option.none => false,
        Option.some _ => true
    }

/// A wire intent as the game's `Intent`, quantized back to units.
pub def intent_of_wire (i : WireIntent) : Intent :=
    intent_ext
        (intent (intent_mx i) (intent_mz i) (intent_jump_pressed i) (intent_jump_held i)
            (intent_dash_pressed i) (intent_sprint i))
        (intent_ability_pressed i) (intent_swap_pressed i)

// ── Which intent drives a Mo ────────────────────────────────────────

// ── What the host ships ─────────────────────────────────────────────

/// The pose of the Mo marked `marker`, as a wire hero. A world without that
/// Mo (a level that has not spawned it) sends the origin, which a guest draws
/// at the origin rather than somewhere wrong.
pub def hero_of (world : World) (marker : String) : WireHero :=
    match List.first (query_entities world [mo_name, marker] []) {
        Option.none => wire_hero 0.0 0.0 0.0 0.0 true,
        Option.some e => hero_of_entity world e
    }

def hero_of_entity (world : World) (e : Entity) : WireHero :=
    let s : MoState := entity_mo world e in
    let p : Vec3 := mo_position world e in
    wire_hero p.x p.y p.z (facing_x s) s.grounded

/// The facing on the wire: its `x` component, with `z` implied (`facing` is a
/// unit vector on the ground plane, and the sign of `z` is carried by the two
/// of them together). Shipping a component beats shipping an angle: no
/// `atan2` is needed either side, and nothing is lost round-tripping.
def facing_x (s : MoState) : F64 :=
    let f : Vec3 := mo_facing s in f.x

/// The facing back out of the wire: `x` from the field, and `z` from the
/// remaining unit length (the game's `facing` is always a unit vector).
def facing_of_wire (h : WireHero) : Vec3 :=
    let x : F64 := hero_yaw h in
    // The facing is a unit vector, so `z` follows from `x` up to its sign; the
    // sign comes from the wire's own `grounded`-independent convention below.
    let z2 : F64 := 1.0 - x * x in
    let z : F64 := if z2 <= 0.0 then 0.0 else f64_sqrt z2 in
    vec3 x 0.0 (0.0 - z)

/// The run's visible state, ready to encode as a `state` frame.
pub def coop_state (world : World) : WireState :=
    let g : GameState := game_or_new world in
    wire_state (world_level_index world) (game_sparks g) (game_total g) (game_falls g)
        (game_time g) (hero_of world player_name) (hero_of world companion_name) (game_won g)

def game_or_new (world : World) : GameState :=
    let g : Option GameState := world_game_opt world in
    game_or_new_of g world

def game_or_new_of (g : Option GameState) (world : World) : GameState :=
    match g {
        Option.none => game_new (world_level world),
        Option.some s => s
    }

/// `coop_state world` as the text a `state` frame carries.
pub def coop_state_text (world : World) : String :=
    net_encode (NetMsg.state (coop_state world))

// ── What a guest does with a state frame ────────────────────────────

/// Fold a host's state frame into the guest's world: the two heroes' poses.
/// This is the one place a remote number is written into a transform -- and
/// the wire has already clamped every coordinate.
pub def apply_state (world : World) (s : WireState) : World :=
    let w1 : World := apply_hero world player_name (state_player s) in
    apply_hero w1 companion_name (state_companion s)

def apply_hero (world : World) (marker : String) (h : WireHero) : World :=
    match List.first (query_entities world [mo_name, marker] []) {
        Option.none => world,
        Option.some e => place_hero world e h
    }

/// Put `e` at the wire hero's pose, keeping the scale and taking the facing
/// from the wire yaw.
def place_hero (world : World) (e : Entity) (h : WireHero) : World :=
    let p : Vec3 := vec3 (hero_x h) (hero_y h) (hero_z h) in
    let moved : World := place_mo world e p (facing_of_wire h) in
    set_grounded moved e h

/// The wire says whether the hero is on the ground; the guest records it so
/// the next animation frame does not flicker between falling and running.
def set_grounded (world : World) (e : Entity) (h : WireHero) : World :=
    let s : MoState := entity_mo world e in
    set_mo world e (mo_with_grounded s (hero_grounded h))

/// A `state` frame's text, folded into the guest's world (a malformed frame
/// leaves the world alone rather than half-applying).
pub def apply_state_text (world : World) (text : String) : World :=
    match net_decode text {
        Result.err _ => world,
        Result.ok m =>
            match m {
                NetMsg.state s => apply_state world s,
                _ => world
            }
    }
// ── The page's co-op hooks ──────────────────────────────────────────
//
// `forge_app::web` owns the socket; it cannot read Mo Venture's components or
// its controls, so the game hands it these five functions (all native, all
// tested here). This is the only place the browser glue meets the game.

/// This page's own input as the intent a guest sends: the same keys-plus-camera
/// rule the host uses for its player, so a guest's hero runs where the guest
/// is looking.
pub def coop_input_intent (world : World) (i : Input) : WireIntent :=
    let game : Intent := keys_intent i (view_orbit world) in
    let dir : Vec3 := intent_move game in
    wire_intent dir.x dir.z game.jump_pressed game.jump_held
        game.dash_pressed game.sprint game.ability_pressed game.swap_pressed

/// Mo Venture's hooks for a co-op page.
pub def mo_coop_hooks : CoopHooks :=
    coop_hooks coop_state_text apply_state_text world_set_guest_intent
        world_clear_guest_intent coop_input_intent
