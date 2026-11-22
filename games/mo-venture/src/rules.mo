// Mo Venture: the rules. Sparks are collected on touch, checkpoints move
// the respawn point forward, falling below the level sends Mo back to the
// last checkpoint, and touching the goal wins. The HUD shows the count,
// the clock, the falls and a message.
//
// What Mo touches comes from forge-collide's `overlap` with Mo's own
// capsule, so a trigger counts the frame Mo's body reaches it.

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, spawn, despawn, insert_component, remove_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math {Vec3, vec3, f64_abs}
use forge_schedule {world_time, time_delta}
use forge_render {set_mesh}
use forge_collide {Pose, pose_at, collision_scene, overlap, layer_all, collider_name}
use forge_animate {Easing, TweenEnd, set_tween, tween_scale, tween_then}
use forge_app {hud_set}
use lib::level {Level}
use lib::look {Post, post_name, spark_name, goal_name}
use lib::mo {find_mo, mo_position, place_mo, set_mo, mo_rest, mo_shape, mo_facing, entity_mo}

// ── State ───────────────────────────────────────────────────────────

pub def msg_none : I64 := 0

pub def msg_checkpoint : I64 := 1

pub def msg_goal : I64 := 2

/// The run so far. `Copy`.
#[derive Copy Clone]
pub struct GameState {
    sparks : I64,
    total : I64,
    falls : I64,
    time : F64,
    respawn : Vec3,
    checkpoint : I64,
    won : Bool,
    kill_y : F64,
    message : I64,
    message_age : F64
}

pub def game_new (lv : Level) : GameState :=
    { sparks := 0, total := List.length lv.sparks, falls := 0, time := 0.0,
      respawn := vec3 lv.start.x (lv.start.y + 0.71) lv.start.z, checkpoint := 0, won := false,
      kill_y := lv.kill_y, message := msg_none, message_age := 0.0 : GameState }

pub def game_sparks (g : GameState) : I64 := g.sparks

pub def game_total (g : GameState) : I64 := g.total

pub def game_falls (g : GameState) : I64 := g.falls

pub def game_time (g : GameState) : F64 := g.time

pub def game_won (g : GameState) : Bool := g.won

pub def game_checkpoint (g : GameState) : I64 := g.checkpoint

pub def game_respawn (g : GameState) : Vec3 := g.respawn

/// Seconds since the last message (a checkpoint, the goal) was set.
pub def game_message_age (g : GameState) : F64 := g.message_age

def with_sparks (g : GameState) (n : I64) : GameState :=
    { sparks := n, total := g.total, falls := g.falls, time := g.time, respawn := g.respawn,
      checkpoint := g.checkpoint, won := g.won, kill_y := g.kill_y, message := g.message,
      message_age := g.message_age : GameState }

def with_checkpoint (g : GameState) (i : I64) (p : Vec3) : GameState :=
    { sparks := g.sparks, total := g.total, falls := g.falls, time := g.time, respawn := p,
      checkpoint := i, won := g.won, kill_y := g.kill_y, message := msg_checkpoint, message_age := 0.0
      : GameState }

def with_won (g : GameState) : GameState :=
    { sparks := g.sparks, total := g.total, falls := g.falls, time := g.time, respawn := g.respawn,
      checkpoint := g.checkpoint, won := true, kill_y := g.kill_y, message := msg_goal, message_age := 0.0
      : GameState }

def with_fall (g : GameState) : GameState :=
    { sparks := g.sparks, total := g.total, falls := g.falls + 1, time := g.time, respawn := g.respawn,
      checkpoint := g.checkpoint, won := g.won, kill_y := g.kill_y, message := g.message,
      message_age := g.message_age : GameState }

/// The clock runs until the goal; a checkpoint message fades after 2 s.
def tick (g : GameState) (dt : F64) : GameState :=
    let age : F64 := g.message_age + dt in
    let msg : I64 := if g.message == msg_checkpoint && age > 2.0 then msg_none else g.message in
    { sparks := g.sparks, total := g.total, falls := g.falls,
      time := if g.won then g.time else g.time + dt, respawn := g.respawn, checkpoint := g.checkpoint,
      won := g.won, kill_y := g.kill_y, message := msg, message_age := age : GameState }

pub def game_name : String := "mo.game"

def as_game (v : Any) : GameState :=
    match v { Any.any x => let g : GameState := x in g }

pub def world_game_opt (world : World) : Option GameState :=
    match List.first (query_entities world [game_name] []) {
        Option.some e =>
            match get_component_named world e game_name {
                Option.some v => Option.some (as_game v),
                Option.none => Option.none
            },
        Option.none => Option.none
    }

pub def world_set_game (world : World) (g : GameState) : World :=
    match List.first (query_entities world [game_name] []) {
        Option.some e => insert_component world e game_name (Any.any g),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair game_name (Any.any g)] in
            s.world
    }

/// The world without a run state (a new level starts a fresh one).
pub def world_clear_game (world : World) : World :=
    match List.first (query_entities world [game_name] []) {
        Option.some e => despawn world e,
        Option.none => world
    }

// ── Touches ─────────────────────────────────────────────────────────

/// The world and game state threaded through the touched entities. `Copy`.
struct Play {
    world : World,
    game : GameState
}

instance Copy Play {
    def copy (p : Play) : Pair Play Play := Pair.pair p p
}

def as_post (v : Any) : Post :=
    match v { Any.any x => let p : Post := x in p }

def reach_post (p : Play) (post : Post) : Play :=
    if post.index > p.game.checkpoint
    then { world := set_mesh p.world post.flag post.lit,
           game := with_checkpoint p.game post.index post.respawn : Play }
    else p

def has_named (world : World) (e : Entity) (name : String) : Bool :=
    match get_component_named world e name {
        Option.some _ => true,
        Option.none => false
    }

/// A collected spark pops: no longer a spark or a trigger, it swells and
/// is despawned at the end of its tween.
def pop_spark (world : World) (e : Entity) : World :=
    let w1 : World := remove_component (remove_component world e spark_name) e collider_name in
    set_tween w1 e (tween_then (tween_scale (vec3 0.32 0.32 0.32) (vec3 0.85 0.85 0.85) 0.22 Easing.quad_out)
                                TweenEnd.end_despawn)

def touch (p : Play) (e : Entity) : Play :=
    if has_named p.world e spark_name
    then { world := pop_spark p.world e, game := with_sparks p.game (p.game.sparks + 1) : Play }
    else if has_named p.world e goal_name
    then (if p.game.won then p else { world := p.world, game := with_won p.game : Play })
    else
        match get_component_named p.world e post_name {
            Option.some v => reach_post p (as_post v),
            Option.none => p
        }

#[terminating]
def touch_all (p : Play) (es : List Entity) : Play :=
    match es {
        List.empty => p,
        List.cons e rest => touch_all (touch p e) rest
    }

/// Below the level: back to the respawn point, at rest.
def fall_check (p : Play) (mo : Entity) (pos : Vec3) : Play :=
    if pos.y < p.game.kill_y
    then { world := set_mo (place_mo p.world mo p.game.respawn (mo_facing (entity_mo p.world mo))) mo mo_rest,
           game := with_fall p.game : Play }
    else p

// ── HUD ─────────────────────────────────────────────────────────────

/// `floor y` for 0 <= y < 2^31, by binary digits (no F64 -> I64 in `init`).
#[terminating]
def trunc_go (y : F64) (p : F64) (pi : I64) (acc : I64) : I64 :=
    if pi == 0 then acc
    else if y >= p then trunc_go (y - p) (p * 0.5) (I64.div pi 2) (acc + pi)
    else trunc_go y (p * 0.5) (I64.div pi 2) acc

pub def trunc_i64 (y : F64) : I64 := if y <= 0.0 then 0 else trunc_go y 1073741824.0 1073741824 0

def pad2 (n : I64) : String := if n < 10 then String.concat "0" (I64.to_string n) else I64.to_string n

/// `x` with one decimal ("12.3").
pub def fmt1 (x : F64) : String :=
    let t : I64 := trunc_i64 (f64_abs x * 10.0 + 0.5) in
    let body : String := String.concat (I64.to_string (I64.div t 10)) (String.concat "." (I64.to_string (I64.rem t 10))) in
    if x < 0.0 && t > 0 then String.concat "-" body else body

/// `x` with two decimals ("-3.05").
pub def fmt2 (x : F64) : String :=
    let t : I64 := trunc_i64 (f64_abs x * 100.0 + 0.5) in
    let body : String := String.concat (I64.to_string (I64.div t 100)) (String.concat "." (pad2 (I64.rem t 100))) in
    if x < 0.0 && t > 0 then String.concat "-" body else body

def message_text (m : I64) : String :=
    if m == msg_goal then "Goal!" else if m == msg_checkpoint then "Checkpoint!" else ""

def show (world : World) (g : GameState) (pos : Vec3) : World :=
    let w1 : World := hud_set world "sparks" (String.concat (I64.to_string g.sparks) (String.concat "/" (I64.to_string g.total))) in
    let w2 : World := hud_set w1 "time" (fmt1 g.time) in
    let w3 : World := hud_set w2 "falls" (I64.to_string g.falls) in
    let w4 : World := hud_set w3 "message" (message_text g.message) in
    hud_set w4 "pos" (String.concat (fmt2 pos.x) (String.concat " " (String.concat (fmt2 pos.y) (String.concat " " (fmt2 pos.z)))))

// ── The system ──────────────────────────────────────────────────────

def rules_for (world : World) (g0 : GameState) (mo : Entity) : World :=
    let pos : Vec3 := mo_position world mo in
    let touched : List Entity := overlap (collision_scene world) mo_shape (pose_at pos) layer_all (Option.some mo) in
    let p1 : Play := touch_all { world := world, game := tick g0 (time_delta (world_time world)) : Play } touched in
    let p2 : Play := fall_check p1 mo pos in
    show (world_set_game p2.world p2.game) p2.game (mo_position p2.world mo)

/// One frame of rules for level `lv` (its state is created on first use).
pub def rules_step (lv : Level) (world : World) : World :=
    let g0 : GameState := match world_game_opt world {
        Option.some g => g,
        Option.none => game_new lv
    } in
    match find_mo world {
        Option.some mo => rules_for world g0 mo,
        Option.none => world
    }

pub def rules_system (lv : Level) : WorldM Id Unit := WorldM.modify (rules_step lv)
