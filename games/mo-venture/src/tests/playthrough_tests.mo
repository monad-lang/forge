// Mo Venture: the slow end-to-end bot playthroughs.
//
// Kept out of `game_tests.mo` so the fast controller/rules/companion suite
// does not have to build the level-wide playthrough code, and so this file can
// be run (and timed) on its own.
//
// Every declaration and import is `#[cfg test]`: a non-test compile ignores
// this file entirely, including the levels and the frame loop it pulls in.

#[cfg test]
use init::copy {Copy}
#[cfg test]
use lib::{
    Level, GameState, tiny_level, skyway, cloud_steps, drift_docks, sun_spire, vine_wall, brick_yard,
    game_new, world_game_opt, game_won, game_sparks, game_falls, game_checkpoint,
    mo_venture_autopilot, find_mo, find_companion, mo_position
}
#[cfg test]
use forge_core::ecs {World}
#[cfg test]
use forge_math {Vec3}
#[cfg test]
use forge_app {App, app_frame_dt, frame_world, app_initial_world, hud_get}

struct Run {
    world : World,
    frames : I64
}

instance Copy Run {
    def copy (r : Run) : Pair Run Run := Pair.pair r r
}

#[cfg test]
def dt : F64 := 1.0 / 60.0

#[cfg test]
def won (w : World) : Bool :=
    match world_game_opt w {
        Option.some g0 => let g : GameState := g0 in game_won g,
        Option.none => false
    }

#[cfg test]
def game_of (w : World) : GameState :=
    match world_game_opt w {
        Option.some g => g,
        Option.none => game_new tiny_level
    }

#[cfg test]
def is_text (o : Option String) (want : String) : Bool :=
    match o {
        Option.some v => v == want,
        Option.none => false
    }

#[cfg test]
#[terminating]
def play (a : App) (w : World) (n : I64) (limit : I64) : Run :=
    if n >= limit || won w then { world := w, frames := n : Run }
    else play a (frame_world (app_frame_dt a w dt)) (n + 1) limit

#[cfg test]
def bot_clears (lv : Level) (limit : I64) : Bool :=
    let a : App := mo_venture_autopilot lv in
    let r : Run := play a (app_initial_world a) 0 limit in
    let g : GameState := game_of r.world in
    game_won g && game_falls g == 0 && game_checkpoint g == 2

#[cfg test]
def pair_positions (w : World) : Option (Pair Vec3 Vec3) :=
    match find_mo w {
        Option.some p =>
            match find_companion w {
                Option.some c => Option.some (Pair.pair (mo_position w p) (mo_position w c)),
                Option.none => Option.none
            },
        Option.none => Option.none
    }

// ── Bot playthroughs ────────────────────────────────────────────────

#[cfg test]
#[test]
def test_bot_finishes_the_tiny_level : Bool :=
    let a : App := mo_venture_autopilot tiny_level in
    let r : Run := play a (app_initial_world a) 0 900 in
    let g : GameState := game_of r.world in
    game_won g && game_sparks g == 1 && game_falls g == 0 && is_text (hud_get r.world "sparks") "1/1"

#[cfg test]
#[test]
def test_bot_finishes_the_skyway : Bool :=
    let a : App := mo_venture_autopilot skyway in
    let r : Run := play a (app_initial_world a) 0 3600 in
    let g : GameState := game_of r.world in
    // The bot's line (edge jumps, aimed landings) passes over a few sparks;
    // it must still take most of them, never fall, and pass both checkpoints.
    game_won g && game_falls g == 0 && game_sparks g >= 15 && game_checkpoint g == 2

#[cfg test]
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

#[cfg test]
#[test]
def test_bot_finishes_cloud_steps : Bool := bot_clears cloud_steps 3600

#[cfg test]
#[test]
def test_bot_finishes_drift_docks : Bool := bot_clears drift_docks 6000

#[cfg test]
#[test]
def test_bot_finishes_sun_spire : Bool := bot_clears sun_spire 6000

#[cfg test]
#[test]
def test_bot_finishes_vine_wall : Bool := bot_clears vine_wall 6000

#[cfg test]
#[test]
def test_bot_finishes_brick_yard : Bool := bot_clears brick_yard 6000

/// The ability levels play the same way twice.
#[cfg test]
#[test]
def test_the_puzzle_levels_are_deterministic : Bool :=
    let a : App := mo_venture_autopilot vine_wall in
    let r1 : Run := play a (app_initial_world a) 0 600 in
    let r2 : Run := play a (app_initial_world a) 0 600 in
    match pair_positions r1.world {
        Option.some p1 =>
            match pair_positions r2.world {
                Option.some p2 =>
                    match p1 { Pair.pair u1 v1 =>
                        match p2 { Pair.pair u2 v2 =>
                            let a1 : Vec3 := u1 in
                            let b1 : Vec3 := v1 in
                            let a2 : Vec3 := u2 in
                            let b2 : Vec3 := v2 in
                            a1.x == a2.x && a1.y == a2.y && a1.z == a2.z
                            && b1.x == b2.x && b1.y == b2.y && b1.z == b2.z } },
                Option.none => false
            },
        Option.none => false
    }
