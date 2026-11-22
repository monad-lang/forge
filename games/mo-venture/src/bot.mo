// Mo Venture: the autopilot. The level's route is a list of landing spots
// (platform tops). The bot runs toward the next one and jumps the way a
// player does: when a downward ray just ahead of Mo finds no ground (an
// edge), or when the spot is a step up close by. A spot marked `act_dash`
// is reached with an air dash at the top of the jump; `act_double` with a
// second jump at the top of the first, `act_double_dash` with both. At an
// `act_wait` spot (a moving platform's near end) the bot stands until the
// platform is there; toward an `act_ride` spot it stands still and lets
// the platform carry it. A spot counts as
// reached once Mo stands at its height near it or past it, so momentum
// never makes the bot circle. After a fall it resumes from the spot
// nearest the respawn point.
//
// It produces an `Intent`, the same thing the keyboard produces, so a bot
// run exercises everything but the key mapping. The tests use it to play
// whole levels; in the browser, P toggles it.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Spawned, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_math {Vec3, vec3, v3_add, v3_sub, v3_dot, v3_length, v3_scale, ray, f64_sqrt, f64_max, f64_min}
use forge_collide {Scene, raycast, layer_all}
use lib::tune {Tune, tune, mo_stand}
use lib::level {Level, Way, act_walk, act_dash, act_double, act_double_dash, act_wait, act_ride}
use lib::mo {Intent, intent, intent_none, MoState}

/// Where the bot is on the route. `Copy`.
#[derive Copy Clone]
pub struct Bot {
    on : Bool,
    index : I64,
    dash_pending : Bool,
    falls : I64
}

pub def bot_off : Bot := { on := false, index := 0, dash_pending := false, falls := 0 : Bot }

pub def bot_on : Bot := { on := true, index := 0, dash_pending := false, falls := 0 : Bot }

pub def bot_is_on (b : Bot) : Bool := b.on

pub def bot_index (b : Bot) : I64 := b.index

pub def bot_toggle (b : Bot) : Bot :=
    { on := Bool.not b.on, index := b.index, dash_pending := false, falls := b.falls : Bot }

/// The same bot (on or off) at the start of a new level's route.
pub def bot_restart (b : Bot) : Bot := { on := b.on, index := 0, dash_pending := false, falls := 0 : Bot }

/// How near (on the ground plane) a landing spot counts as reached.
pub def arrive : F64 := 1.0

def flat (v : Vec3) : Vec3 := vec3 v.x 0.0 v.z

/// The intent and the bot's next state. `Copy`.
#[derive Copy Clone]
pub struct Thought {
    intent : Intent,
    bot : Bot
}

pub def thought_intent (t : Thought) : Intent := t.intent

pub def thought_bot (t : Thought) : Bot := t.bot

def point_at (lv : Level) (i : I64) : Option Vec3 :=
    match List.get i lv.route {
        Option.some w0 => let w : Way := w0 in Option.some w.at,
        Option.none => Option.none
    }

def prev_point (lv : Level) (i : I64) : Vec3 :=
    if i == 0 then lv.start
    else match point_at lv (i - 1) {
        Option.some p => p,
        Option.none => lv.start
    }

/// Unit direction from `pos` toward `p` on the ground plane (zero when on it).
def toward (pos : Vec3) (p : Vec3) : Vec3 :=
    let d : Vec3 := flat (v3_sub p pos) in
    let len : F64 := v3_length d in
    if len < 0.0001 then vec3 0.0 0.0 0.0 else v3_scale d (1.0 / len)

/// Is there ground under the point `ahead` units in front of Mo (feet at
/// `feet`)? A ray from just above the feet, down by most of a step.
def ground_ahead (sc : Scene) (pos : Vec3) (dir : Vec3) (feet : F64) : Bool :=
    let probe : Vec3 := v3_add pos (v3_scale dir 0.6) in
    match raycast sc (ray (vec3 probe.x (feet + 0.3) probe.z) (vec3 0.0 (0.0 - 1.0) 0.0)) 0.9 layer_all {
        Option.some _ => true,
        Option.none => false
    }

/// Is there ground just under the platform-top point `p`? (A moving
/// platform is at this end of its path.)
def ground_at (sc : Scene) (p : Vec3) : Bool :=
    match raycast sc (ray (vec3 p.x (p.y + 0.5) p.z) (vec3 0.0 (0.0 - 1.0) 0.0)) 1.0 layer_all {
        Option.some _ => true,
        Option.none => false
    }

/// The fraction of run speed that covers `gap` before Mo, rising at `vy`
/// and `above` the landing height, comes down to it.
def aim (t : Tune) (vy : F64) (above : F64) (gap : F64) : F64 :=
    let disc : F64 := vy * vy + 2.0 * t.gravity * above in
    let fall : F64 := if disc > 0.0 then (vy + f64_sqrt disc) / t.gravity else 0.0 in
    let speed : F64 := gap / f64_max fall 0.05 in
    f64_min 1.0 (speed / t.run_speed)

def think_at (lv : Level) (sc : Scene) (b : Bot) (s : MoState) (pos : Vec3) (w : Way) : Thought :=
    let feet : F64 := pos.y - mo_stand in
    let to : Vec3 := flat (v3_sub w.at pos) in
    let seg : Vec3 := flat (v3_sub w.at (prev_point lv b.index)) in
    let near_or_past : Bool := v3_length to < arrive || v3_dot to seg <= 0.0 in
    let landed : Bool := s.grounded && feet > w.at.y - 0.3 && near_or_past in
    let next : I64 := if landed then b.index + 1 else b.index in
    let target : Vec3 := match point_at lv next {
        Option.some p => p,
        Option.none => w.at
    } in
    let dir : Vec3 := toward pos target in
    let moving : Bool := v3_length dir > 0.5 in
    let edge : Bool := moving && Bool.not (ground_ahead sc pos dir feet) in
    let step_up : Bool := target.y - feet > 0.3 && v3_length (flat (v3_sub target pos)) < 2.2 in
    let act : I64 := match List.get next lv.route {
        Option.some n0 => let n : Way := n0 in n.act,
        Option.none => act_walk
    } in
    // Movers: stand while the platform is away (wait) or carrying Mo (ride).
    let hold : Bool := act == act_ride || (act == act_wait && s.grounded && Bool.not (ground_at sc target)) in
    let jump : Bool := Bool.not hold && s.grounded && (edge || step_up) in
    let air_spot : Bool := act == act_double || act == act_double_dash in
    let dash_spot : Bool := act == act_dash || act == act_double_dash in
    let air_jump : Bool := air_spot && Bool.not s.grounded && s.vel.y <= 0.0 && s.air_used == 0 in
    let dash : Bool := dash_spot && Bool.not s.grounded && s.vel.y <= 1.0 && Bool.not s.dashed
                           && (act == act_dash || s.air_used >= 1) in
    let done : Bool := next >= List.length lv.route in
    // In the air, aim: the horizontal speed that arrives over the spot when
    // Mo comes down to its height (air control does the rest). A dash spot
    // wants every bit of distance, so it is not throttled, and neither is
    // the first half of a double jump.
    let gap : F64 := v3_length (flat (v3_sub target pos)) in
    let full : Bool := s.grounded || dash_spot || (air_spot && s.air_used == 0) in
    let mag : F64 := if full then 1.0 else aim tune s.vel.y (pos.y - (target.y + mo_stand)) gap in
    let m : Vec3 := if done || hold then vec3 0.0 0.0 0.0 else v3_scale dir mag in
    { intent := intent m.x m.z (jump || air_jump) true dash false,
      bot := { on := true, index := next, dash_pending := false, falls := b.falls : Bot }
      : Thought }

/// One frame of autopilot for Mo at `pos` in state `s`, looking at the
/// level's colliders `sc`.
pub def bot_think (lv : Level) (sc : Scene) (b : Bot) (s : MoState) (pos : Vec3) : Thought :=
    match List.get b.index lv.route {
        Option.some w0 => think_at lv sc b s pos w0,
        Option.none => { intent := intent_none, bot := b : Thought }
    }

#[terminating]
def nearest_go (ws : List Way) (pos : Vec3) (i : I64) (best : I64) (best_d : F64) : I64 :=
    match ws {
        List.empty => best,
        List.cons w0 rest =>
            let w : Way := w0 in
            let d : F64 := v3_length (v3_sub w.at pos) in
            if d < best_d then nearest_go rest pos (i + 1) i d else nearest_go rest pos (i + 1) best best_d
    }

/// After Mo has fallen `falls` times in all: if that is a new fall, carry
/// on from the landing spot nearest Mo (the respawn point).
pub def bot_resync (lv : Level) (b : Bot) (pos : Vec3) (falls : I64) : Bot :=
    if falls > b.falls
    then { on := b.on, index := nearest_go lv.route pos 0 0 1000000000.0, dash_pending := false, falls := falls : Bot }
    else b

/// Has the bot run out of route?
pub def bot_done (lv : Level) (b : Bot) : Bool := b.index >= List.length lv.route

// ── Resource ────────────────────────────────────────────────────────

pub def bot_name : String := "mo.bot"

def as_bot (v : Any) : Bot :=
    match v { Any.any x => let b : Bot := x in b }

pub def world_bot (world : World) : Bot :=
    match List.first (query_entities world [bot_name] []) {
        Option.some e =>
            match get_component_named world e bot_name {
                Option.some v => as_bot v,
                Option.none => bot_off
            },
        Option.none => bot_off
    }

pub def world_set_bot (world : World) (b : Bot) : World :=
    match List.first (query_entities world [bot_name] []) {
        Option.some e => insert_component world e bot_name (Any.any b),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair bot_name (Any.any b)] in
            s.world
    }
