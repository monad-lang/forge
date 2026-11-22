// Mo Venture: the Skyway level, as data.
//
// A course of floating platforms running along -z: a start island, three
// stairs, a gap, a narrow bridge, the first checkpoint, a diagonal climb, a
// gap too wide to jump without the air dash, the second checkpoint, a high
// ledge and the goal beacon. 20 sparks sit along the way, at the height of
// Mo's body, so following the route collects them.
//
// `route` is the autopilot's list of landing spots (platform tops), one
// marked `act_dash` where the gap needs the air dash.
//
// A platform may MOVE: `mover` gives it a second centre, and it travels
// there and back (`mover_dwell` s at each end, `mover_travel` s between),
// carrying Mo. The other levels live in `levels.mo`.

use std::derive {}
use init::copy {Copy}
use forge_math {Vec3, vec3}

/// What a platform is made of (its look; all are solid). `Copy`.
pub def kind_grass : I64 := 0

pub def kind_stone : I64 := 1

pub def kind_wood : I64 := 2

pub def kind_gold : I64 := 3

/// A wall Xiaomao can climb (green; its collider is on the climb layer).
pub def kind_climb : I64 := 4

/// A box platform: centre, half extents and kind. A moving one also has
/// the far end of its path, `to` (a still one has `to = center`). `Copy`.
#[derive Copy Clone]
pub struct Plat {
    center : Vec3,
    half : Vec3,
    kind : I64,
    to : Vec3,
    moves : Bool
}

pub def plat (cx : F64) (cy : F64) (cz : F64) (hx : F64) (hy : F64) (hz : F64) (kind : I64) : Plat :=
    { center := vec3 cx cy cz, half := vec3 hx hy hz, kind := kind, to := vec3 cx cy cz, moves := false : Plat }

/// A platform that shuttles between its centre and `(tx, ty, tz)`.
pub def mover (cx : F64) (cy : F64) (cz : F64) (hx : F64) (hy : F64) (hz : F64) (kind : I64)
    (tx : F64) (ty : F64) (tz : F64) : Plat :=
    { center := vec3 cx cy cz, half := vec3 hx hy hz, kind := kind, to := vec3 tx ty tz, moves := true : Plat }

pub def plat_top (p : Plat) : F64 := p.center.y + p.half.y

pub def plat_moves (p : Plat) : Bool := p.moves

pub def plat_to (p : Plat) : Vec3 := p.to

/// The same platform at the far end of its path (itself if it is still).
pub def plat_at_end (p : Plat) : Plat :=
    { center := p.to, half := p.half, kind := p.kind, to := p.to, moves := p.moves : Plat }

/// A mover rests `2 * mover_dwell` s at each end and takes `mover_travel`
/// s between them, so a whole there-and-back cycle is
/// `2 * (2 * mover_dwell + mover_travel)` = 10 s.
pub def mover_dwell : F64 := 1.0

pub def mover_travel : F64 := 3.0

/// Route actions.
pub def act_walk : I64 := 0

pub def act_jump : I64 := 1

pub def act_dash : I64 := 2

/// Jump, then jump again in the air at the top of the first.
pub def act_double : I64 := 3

/// Jump, air-jump, and air-dash at the top of the second.
pub def act_double_dash : I64 := 4

/// A spot on a moving platform's near end: wait until the platform is
/// there (ground under the spot), then jump on.
pub def act_wait : I64 := 5

/// The moving platform's far end: stand still and let it carry Mo there.
pub def act_ride : I64 := 6

/// Press the ability key (`X`) at the spot: spin or slam, whoever it is.
pub def act_ability : I64 := 7

/// Slam a wall of boxes ahead (Xiaozhu, in the air).
pub def act_slam : I64 := 8

/// Spin next to a switch (Xiaomao, on the ground).
pub def act_spin : I64 := 9

/// Climb the wall ahead (Xiaomao; the controller climbs automatically).
pub def act_climb : I64 := 10

/// Be controlling Xiaomao here (swap if the piggy is controlled).
pub def act_as_kitty : I64 := 11

/// Be controlling Xiaozhu here (swap if the kitty is controlled).
pub def act_as_piggy : I64 := 12

/// A landing spot on a platform top, and how to get there. `Copy`.
#[derive Copy Clone]
pub struct Way {
    at : Vec3,
    act : I64
}


pub def way_at (w : Way) : Vec3 := w.at

pub def way_act (w : Way) : I64 := w.act

/// A switch Xiaomao's spin trips: it opens every gate with the same id.
/// `Copy`.
#[derive Copy Clone]
pub struct Switch {
    at : Vec3,
    gate : I64
}

pub def switch_at (x : F64) (y : F64) (z : F64) (gate : I64) : Switch :=
    { at := vec3 x y z, gate := gate : Switch }

pub def switch_pos (s : Switch) : Vec3 := s.at

pub def switch_gate (s : Switch) : I64 := s.gate

/// A solid bar that a switch opens (it sinks away). `Copy`.
#[derive Copy Clone]
pub struct Gate {
    at : Vec3,
    half : Vec3,
    gate : I64
}

pub def gate_box (x : F64) (y : F64) (z : F64) (hx : F64) (hy : F64) (hz : F64) (gate : I64) : Gate :=
    { at := vec3 x y z, half := vec3 hx hy hz, gate := gate : Gate }

pub def gate_pos (g : Gate) : Vec3 := g.at

pub def gate_half (g : Gate) : Vec3 := g.half

pub def gate_id (g : Gate) : I64 := g.gate

/// A whole level. `Copy` (identity: persistent lists). `climbs` are walls
/// (kept out of `plats` so the jump reachability tests never see them);
/// `boxes`, `switches` and `gates` are the puzzle props.
pub struct Level {
    name : String,
    plats : List Plat,
    climbs : List Plat,
    boxes : List Vec3,
    switches : List Switch,
    gates : List Gate,
    sparks : List Vec3,
    posts : List Vec3,
    goal : Vec3,
    start : Vec3,
    kill_y : F64,
    route : List Way
}

pub instance Copy Level {
    def copy (l : Level) : Pair Level Level := Pair.pair l l
}

pub def level_name (l : Level) : String := l.name

pub def level_plats (l : Level) : List Plat := l.plats

pub def level_climbs (l : Level) : List Plat := l.climbs

pub def level_boxes (l : Level) : List Vec3 := l.boxes

pub def level_switches (l : Level) : List Switch := l.switches

pub def level_gates (l : Level) : List Gate := l.gates

pub def level_sparks (l : Level) : List Vec3 := l.sparks

pub def level_posts (l : Level) : List Vec3 := l.posts

pub def level_goal (l : Level) : Vec3 := l.goal

pub def level_start (l : Level) : Vec3 := l.start

pub def level_kill_y (l : Level) : F64 := l.kill_y

pub def level_route (l : Level) : List Way := l.route

pub def level_spark_count (l : Level) : I64 := List.length l.sparks

pub def level_new (name : String) (plats : List Plat) (sparks : List Vec3) (posts : List Vec3) (goal : Vec3)
    (start : Vec3) (kill_y : F64) (route : List Way) : Level :=
    { name := name, plats := plats, climbs := List.empty, boxes := List.empty,
      switches := List.empty, gates := List.empty, sparks := sparks, posts := posts, goal := goal,
      start := start, kill_y := kill_y, route := route
      : Level }

/// `lv` with puzzle props: climb walls, breakable boxes, switches and the
/// gates they open.
pub def level_puzzles (lv : Level) (climbs : List Plat) (boxes : List Vec3)
    (switches : List Switch) (gates : List Gate) : Level :=
    { name := lv.name, plats := lv.plats, climbs := climbs, boxes := boxes,
      switches := switches, gates := gates, sparks := lv.sparks, posts := lv.posts,
      goal := lv.goal, start := lv.start, kill_y := lv.kill_y, route := lv.route
      : Level }

pub def way (x : F64) (y : F64) (z : F64) (act : I64) : Way := { at := vec3 x y z, act := act : Way }

pub def n (x : F64) : F64 := 0.0 - x

// ── Skyway ──────────────────────────────────────────────────────────

/// Platform tops: start 0, stairs 0.6 / 1.2 / 1.8, then 1.8 to the first
/// checkpoint, the climb 2.4 / 3.0 / 3.6, 3.6 to the second checkpoint,
/// and 5.0 for the ledge and the goal.
def skyway_plats : List Plat :=
    [ plat 0.0 (n 0.5) 0.0 3.0 0.5 3.0 kind_grass,          // start island, z -3..3
      plat 0.0 0.1 (n 4.0) 1.5 0.5 1.0 kind_stone,          // stair, top 0.6
      plat 0.0 0.7 (n 6.0) 1.5 0.5 1.0 kind_stone,          // stair, top 1.2
      plat 0.0 1.3 (n 8.0) 1.5 0.5 1.0 kind_stone,          // stair, top 1.8, z -9..-7
      plat 0.0 1.3 (n 12.0) 1.5 0.5 1.5 kind_grass,         // after a 1.5 gap, z -13.5..-10.5
      plat 0.0 1.55 (n 17.5) 0.45 0.25 3.0 kind_wood,       // bridge, z -20.5..-14.5
      plat 0.0 1.3 (n 23.5) 2.5 0.5 2.5 kind_grass,         // checkpoint 1, z -26..-21
      plat (n 1.3) 1.9 (n 29.0) 1.2 0.5 1.2 kind_stone,     // climb, top 2.4, z -30.2..-27.8
      plat (n 2.15) 2.5 (n 32.5) 1.2 0.5 1.2 kind_stone,    // climb, top 3.0
      plat (n 3.0) 3.1 (n 36.0) 1.2 0.5 1.2 kind_stone,     // climb, top 3.6, z -37.2..-34.8
      plat (n 3.0) 3.1 (n 44.3) 1.5 0.5 1.5 kind_grass,     // past the 5.6 dash gap, z -45.8..-42.8
      plat (n 3.0) 3.1 (n 50.5) 2.5 0.5 2.5 kind_grass,     // checkpoint 2, z -53..-48
      plat (n 3.0) 4.5 (n 56.5) 2.0 0.5 1.5 kind_stone,     // high ledge, top 5.0, z -58..-55
      plat (n 3.0) 4.5 (n 62.5) 2.5 0.5 2.5 kind_gold ]     // goal, z -65..-60

/// Sparks at platform top + 0.7: the height of Mo's body.
def skyway_sparks : List Vec3 :=
    [ vec3 0.0 0.7 (n 0.5), vec3 0.0 0.7 (n 2.0),
      vec3 0.0 1.3 (n 4.0), vec3 0.0 1.9 (n 6.0), vec3 0.0 2.5 (n 8.0),
      vec3 0.0 2.5 (n 12.0),
      vec3 0.0 2.5 (n 15.5), vec3 0.0 2.5 (n 17.5), vec3 0.0 2.5 (n 19.5),
      vec3 0.0 2.5 (n 22.0), vec3 0.0 2.5 (n 25.0),
      vec3 (n 1.3) 3.1 (n 29.0), vec3 (n 2.15) 3.7 (n 32.5), vec3 (n 3.0) 4.3 (n 36.0),
      vec3 (n 3.0) 4.3 (n 43.6), vec3 (n 3.0) 4.3 (n 45.0),
      vec3 (n 3.0) 4.3 (n 50.5),
      vec3 (n 3.0) 5.7 (n 56.5),
      vec3 (n 3.0) 5.7 (n 61.0), vec3 (n 3.0) 5.7 (n 63.5) ]

/// The two checkpoint platforms' centres (on their tops). A checkpoint is
/// a trigger across the platform there; its post stands to one side.
def skyway_posts : List Vec3 := [vec3 0.0 1.8 (n 23.5), vec3 (n 3.0) 3.6 (n 50.5)]

/// Landing spots in order; the autopilot jumps edges and steps on its own.
def skyway_route : List Way :=
    [ way 0.0 0.6 (n 4.0) act_walk,
      way 0.0 1.2 (n 6.0) act_walk,
      way 0.0 1.8 (n 8.0) act_walk,
      way 0.0 1.8 (n 12.0) act_walk,
      way 0.0 1.8 (n 17.5) act_walk,
      way 0.0 1.8 (n 23.5) act_walk,
      way (n 1.3) 2.4 (n 29.0) act_walk,
      way (n 2.15) 3.0 (n 32.5) act_walk,
      way (n 3.0) 3.6 (n 36.0) act_walk,
      way (n 3.0) 3.6 (n 44.3) act_dash,
      way (n 3.0) 3.6 (n 50.5) act_walk,
      way (n 3.0) 5.0 (n 56.5) act_walk,
      way (n 3.0) 5.0 (n 62.5) act_walk ]

/// The Skyway: Mo starts on the island facing -z.
pub def skyway : Level :=
    level_new "Skyway" skyway_plats skyway_sparks skyway_posts (vec3 (n 3.0) 5.0 (n 62.5)) (vec3 0.0 0.0 1.5)
              (n 8.0) skyway_route

/// A three-platform level for quick tests: walk, jump a 1.5 gap, step up a
/// 0.6 rise with a jump, reach the goal. One spark on the way.
pub def tiny_level : Level :=
    level_new "Tiny"
        [ plat 0.0 (n 0.5) 0.0 2.0 0.5 2.0 kind_grass,
          plat 0.0 (n 0.5) (n 5.5) 1.5 0.5 1.5 kind_grass,
          plat 0.0 0.1 (n 10.0) 1.5 0.5 1.5 kind_gold ]
        [vec3 0.0 0.7 (n 5.5)]
        []
        (vec3 0.0 0.6 (n 10.0))
        (vec3 0.0 0.0 1.0)
        (n 8.0)
        [ way 0.0 0.0 (n 5.5) act_walk,
          way 0.0 0.6 (n 10.0) act_walk ]
