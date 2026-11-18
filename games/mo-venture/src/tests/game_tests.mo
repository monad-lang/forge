// Mo Venture: the controller's feel, the level's reachability, the rules,
// and whole bot playthroughs through forge_app's frame loop.

use init::copy {Copy}
use lib::{
    Tune, tune, mo_stand, Level, Plat, level_plats, level_route, tiny_level, skyway, plat_top, way_act, act_dash,
    Intent, intent, intent_none, MoState, mo_rest, mo_airborne, mo_vel, mo_grounded, mo_dashed, mo_velocity, mo_with_vel,
    mo_step, MoStep, step_state, step_pos, find_mo, mo_position,
    GameState, game_new, world_game_opt, game_sparks, game_total, game_falls, game_won, game_checkpoint,
    fmt1, fmt2, trunc_i64, mo_venture_on, mo_venture_autopilot
}
use forge_core::ecs {World, Entity, entity_new}
use forge_math {Vec3, vec3, v3_zero, f64_abs, f64_sqrt}
use forge_collide {Scene, scene_of, entry_new, collider, shape_box, pose_at}
use forge_app {App, Frame, app_frame_dt, frame_world, app_initial_world, hud_get}

def near (e : F64) (a : F64) (b : F64) : Bool := f64_abs (a - b) < e

def dt : F64 := 1.0 / 60.0

// ── Jump physics (no level) ─────────────────────────────────────────

#[terminating]
def fly (s : MoState) (y : F64) (top : F64) (hold : Bool) (n : I64) : F64 :=
    if n > 200 then top
    else
        let s1 : MoState := mo_velocity tune s (intent 0.0 0.0 (n == 0) hold false false) dt in
        let v : Vec3 := mo_vel s1 in
        let y1 : F64 := y + v.y * dt in
        if y1 < 0.0 then top
        else fly s1 y1 (if y1 > top then y1 else top) hold (n + 1)

#[test]
def test_full_jump_reaches_its_apex : Bool :=
    // v^2 / 2g = 1.62, within one frame of integration error.
    near 0.1 (fly mo_rest 0.0 0.0 true 0) 1.62

#[test]
def test_released_jump_is_lower : Bool :=
    fly mo_rest 0.0 0.0 false 0 < 0.6

/// Grounded Mo walked off a ledge `t` seconds ago, pressing jump now.
def airborne_for (t : F64) : MoState :=
    mo_velocity tune mo_airborne intent_none t

#[test]
def test_coyote_jump_counts_shortly_after_leaving : Bool :=
    let s : MoState := mo_velocity tune (airborne_for 0.08) (intent 0.0 0.0 true true false false) 0.0 in
    let v : Vec3 := mo_vel s in
    v.y > 8.0

#[test]
def test_coyote_jump_expires : Bool :=
    let s : MoState := mo_velocity tune (airborne_for 0.15) (intent 0.0 0.0 true true false false) 0.0 in
    let v : Vec3 := mo_vel s in
    v.y < 0.0

#[test]
def test_one_dash_per_airtime : Bool :=
    let up : MoState := mo_velocity tune mo_rest (intent 0.0 (0.0 - 1.0) true true false false) dt in
    let d1 : MoState := mo_velocity tune up (intent 0.0 (0.0 - 1.0) false true true false) dt in
    let d2 : MoState := mo_velocity tune (mo_with_vel d1 (vec3 0.0 0.0 (0.0 - 7.0))) (intent 0.0 (0.0 - 1.0) false true true false) dt in
    let v1 : Vec3 := mo_vel d1 in
    let v2 : Vec3 := mo_vel d2 in
    mo_dashed d1 && near 0.5 v1.z (0.0 - 13.0) && v2.z > (0.0 - 8.0)

// ── On a floor ──────────────────────────────────────────────────────

def floor : Scene := scene_of [entry_new (entity_new 1u64 0u64) (collider (shape_box (vec3 20.0 0.5 20.0))) (pose_at (vec3 0.0 (0.0 - 0.5) 0.0))]

#[terminating]
def run (s : MoState) (p : Vec3) (i : Intent) (n : I64) : MoStep :=
    let st : MoStep := mo_step tune floor Option.none s p i dt in
    if n <= 1 then st else run (step_state st) (step_pos st) i (n - 1)

#[test]
def test_running_reaches_run_speed : Bool :=
    let st : MoStep := run mo_rest (vec3 0.0 (mo_stand + 0.01) 0.0) (intent 0.0 (0.0 - 1.0) false false false false) 30 in
    let v : Vec3 := mo_vel (step_state st) in
    near 0.01 v.z (0.0 - 7.0) && mo_grounded (step_state st)

#[test]
def test_buffered_jump_fires_on_landing : Bool :=
    // Falling from 0.3 above the floor, jump pressed 2 frames before contact.
    let falling : MoState := mo_with_vel mo_airborne (vec3 0.0 (0.0 - 3.0) 0.0) in
    let a : MoStep := mo_step tune floor Option.none falling (vec3 0.0 (mo_stand + 0.1) 0.0) (intent 0.0 0.0 true true false false) dt in
    let b : MoStep := run (step_state a) (step_pos a) (intent 0.0 0.0 false true false false) 4 in
    let v : Vec3 := mo_vel (step_state b) in
    v.y > 5.0

// ── Level reachability ──────────────────────────────────────────────

/// Horizontal distance a jump at run speed covers before falling back to
/// `dy` above its start (by the same integrator Mo uses).
#[terminating]
def reach_go (s : MoState) (x : F64) (y : F64) (dy : F64) (dash : Bool) (n : I64) : F64 :=
    if n > 400 then x
    else
        let press : Bool := n == 0 in
        let v0 : Vec3 := mo_vel s in
        let dashing : Bool := dash && n > 0 && v0.y <= 1.0 in
        let s1 : MoState := mo_velocity tune s (intent 0.0 (0.0 - 1.0) press true dashing false) dt in
        let v : Vec3 := mo_vel s1 in
        let x1 : F64 := x - v.z * dt in
        let y1 : F64 := y + v.y * dt in
        if v.y < 0.0 && y1 < dy then x1 else reach_go s1 x1 y1 dy dash (n + 1)

def reach (dy : F64) (dash : Bool) : F64 :=
    reach_go (mo_with_vel mo_rest (vec3 0.0 0.0 (0.0 - 7.0))) 0.0 0.0 dy dash 0

def edge_gap (a : Plat) (b : Plat) : F64 :=
    let gx : F64 := f64_abs (a.center.x - b.center.x) - a.half.x - b.half.x in
    let gz : F64 := f64_abs (a.center.z - b.center.z) - a.half.z - b.half.z in
    let x : F64 := if gx > 0.0 then gx else 0.0 in
    let z : F64 := if gz > 0.0 then gz else 0.0 in
    f64_sqrt (x * x + z * z)

#[terminating]
def gaps_ok (ps : List Plat) (dash_after : I64) (i : I64) : Bool :=
    match ps {
        List.empty => true,
        List.cons a rest =>
            match List.first rest {
                Option.none => true,
                Option.some b0 =>
                    let b : Plat := b0 in
                    let dy : F64 := plat_top b - plat_top a in
                    let limit : F64 := 0.8 * reach dy (i == dash_after) in
                    edge_gap a b <= limit && dy <= 1.5 && gaps_ok rest dash_after (i + 1)
            }
    }

#[test]
def test_jump_reach_is_about_five_units : Bool :=
    let r : F64 := reach 0.0 false in
    r > 4.8 && r < 5.3

#[test]
def test_dash_reaches_further : Bool := reach 0.0 true > reach 0.0 false + 1.5

#[test]
def test_every_skyway_gap_is_reachable : Bool :=
    // Platform 9 -> 10 is the dash gap.
    gaps_ok (level_plats skyway) 9 0

#[test]
def test_the_dash_gap_needs_the_dash : Bool :=
    match List.get 9 (level_plats skyway) {
        Option.some a0 =>
            match List.get 10 (level_plats skyway) {
                Option.some b0 => let a : Plat := a0 in let b : Plat := b0 in edge_gap a b > reach 0.0 false,
                Option.none => false
            },
        Option.none => false
    }

// ── Formatting ──────────────────────────────────────────────────────

#[test]
def test_formatting : Bool :=
    fmt1 12.34 == "12.3" && fmt2 (0.0 - 3.051) == "-3.05" && fmt2 0.004 == "0.00" && trunc_i64 7.99 == 7

// ── Playthroughs ────────────────────────────────────────────────────

/// Frames until the goal (or `limit`), with the game state at the end.
struct Run {
    world : World,
    frames : I64
}

instance Copy Run {
    def copy (r : Run) : Pair Run Run := Pair.pair r r
}

def won (w : World) : Bool :=
    match world_game_opt w {
        Option.some g0 => let g : GameState := g0 in game_won g,
        Option.none => false
    }

#[terminating]
def play (a : App) (w : World) (n : I64) (limit : I64) : Run :=
    if n >= limit || won w then { world := w, frames := n : Run }
    else play a (frame_world (app_frame_dt a w dt)) (n + 1) limit

def game_of (w : World) : GameState :=
    match world_game_opt w {
        Option.some g => g,
        Option.none => game_new tiny_level
    }

def is_text (o : Option String) (want : String) : Bool :=
    match o {
        Option.some v => v == want,
        Option.none => false
    }

#[test]
def test_bot_finishes_the_tiny_level : Bool :=
    let a : App := mo_venture_autopilot tiny_level in
    let r : Run := play a (app_initial_world a) 0 900 in
    let g : GameState := game_of r.world in
    game_won g && game_sparks g == 1 && game_falls g == 0 && is_text (hud_get r.world "sparks") "1/1"

#[test]
def test_idle_mo_stays_put : Bool :=
    let a : App := mo_venture_on tiny_level in
    let r : Run := play a (app_initial_world a) 0 60 in
    match find_mo r.world {
        Option.some e => let p : Vec3 := mo_position r.world e in near 0.02 p.z 1.0 && near 0.02 p.y (mo_stand + 0.01),
        Option.none => false
    }

#[test]
def test_bot_finishes_the_skyway : Bool :=
    let a : App := mo_venture_autopilot skyway in
    let r : Run := play a (app_initial_world a) 0 3600 in
    let g : GameState := game_of r.world in
    // The bot's line (edge jumps, aimed landings) passes over a few sparks;
    // it must still take most of them, never fall, and pass both checkpoints.
    game_won g && game_falls g == 0 && game_sparks g >= 15 && game_checkpoint g == 2

#[test]
def test_bot_runs_are_deterministic : Bool :=
    let a : App := mo_venture_autopilot tiny_level in
    let r1 : Run := play a (app_initial_world a) 0 240 in
    let r2 : Run := play a (app_initial_world a) 0 240 in
    match find_mo r1.world {
        Option.some e1 =>
            match find_mo r2.world {
                Option.some e2 =>
                    let p1 : Vec3 := mo_position r1.world e1 in
                    let p2 : Vec3 := mo_position r2.world e2 in
                    p1.x == p2.x && p1.y == p2.y && p1.z == p2.z,
                Option.none => false
            },
        Option.none => false
    }
