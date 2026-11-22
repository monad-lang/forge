// Mo Venture: the controller's feel, the level's reachability, the rules,
// and whole bot playthroughs through forge_app's frame loop.

use init::copy {Copy}
use lib::{
    Tune, tune, mo_stand, Level, Plat, level_plats, level_route, tiny_level, skyway, plat_top, way_act, act_dash,
    act_walk, act_double, act_double_dash, plat, mover, plat_at_end, level_new, way, act_wait, act_ride, kind_grass,
    kind_wood, cloud_steps, drift_docks, sun_spire, world_level_index, mo_venture_levels_autopilot, game_checkpoint,
    Intent, intent, intent_none, MoState, mo_rest, mo_airborne, mo_vel, mo_grounded, mo_dashed, mo_velocity, mo_with_vel,
    mo_air_used, mo_with_air_used,
    mo_step, MoStep, step_state, step_pos, find_mo, mo_position,
    GameState, game_new, world_game_opt, game_sparks, game_total, game_falls, game_won, game_checkpoint,
    fmt1, fmt2, trunc_i64, mo_venture_on, mo_venture_autopilot, mo_venture_levels, world_hero, hero_xiaozhu,
    hero_xiaomao, hero_name
}
use forge_core::ecs {World, Entity, entity_new}
use forge_math {Vec3, vec3, v3_zero, f64_abs, f64_sqrt}
use forge_collide {Scene, scene_of, entry_new, collider, shape_box, pose_at}
use forge_app {
    App, Frame, app_frame_dt, frame_world, app_initial_world, hud_get, world_set_input, input_apply, input_empty,
    input_key_down
}
use forge_scene {children_of}
use forge_render {Light, world_light, light_shadows}

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

/// A tap (Space down and up inside one frame) is a short hop, but a real
/// one: the cut waits `min_hop` seconds. It used to be cut on its first
/// frame to ~0.4 units, which read as a dropped jump.
#[test]
def test_tapped_jump_is_a_real_short_hop : Bool :=
    let h : F64 := fly mo_rest 0.0 0.0 false 0 in
    h > 1.0 && h < 1.4

/// Like `fly`, pressing again (once) at the apex.
#[terminating]
def fly2 (s : MoState) (y : F64) (top : F64) (again : Bool) (n : I64) : F64 :=
    if n > 300 then top
    else
        let v0 : Vec3 := mo_vel s in
        let press : Bool := n == 0 || (again && n > 1 && v0.y <= 0.0 && mo_air_used s == 0) in
        let s1 : MoState := mo_velocity tune s (intent 0.0 0.0 press true false false) dt in
        let v : Vec3 := mo_vel s1 in
        let y1 : F64 := y + v.y * dt in
        if y1 < 0.0 then top
        else fly2 s1 y1 (if y1 > top then y1 else top) again (n + 1)

#[test]
def test_air_jump_adds_height : Bool :=
    // 1.62 for the ground jump, then 8^2 / 50 = 1.28 more from the apex.
    near 0.15 (fly2 mo_rest 0.0 0.0 true 0) 2.9

#[test]
def test_one_air_jump_per_airtime : Bool :=
    let up : MoState := mo_velocity tune mo_rest (intent 0.0 0.0 true true false false) dt in
    let fall : MoState := mo_with_vel up (vec3 0.0 (0.0 - 2.0) 0.0) in
    let a1 : MoState := mo_velocity tune fall (intent 0.0 0.0 true true false false) dt in
    let a2 : MoState := mo_velocity tune (mo_with_vel a1 (vec3 0.0 (0.0 - 2.0) 0.0)) (intent 0.0 0.0 true true false false) dt in
    let v1 : Vec3 := mo_vel a1 in
    let v2 : Vec3 := mo_vel a2 in
    v1.y > 7.0 && mo_air_used a1 == 1 && v2.y < 0.0

/// Grounded Mo walked off a ledge `t` seconds ago, pressing jump now.
def airborne_for (t : F64) : MoState :=
    mo_velocity tune mo_airborne intent_none t

#[test]
def test_coyote_jump_counts_shortly_after_leaving : Bool :=
    let s : MoState := mo_velocity tune (airborne_for 0.08) (intent 0.0 0.0 true true false false) 0.0 in
    let v : Vec3 := mo_vel s in
    v.y > 8.0

/// Past coyote time a press is no ground jump: it spends the air jump
/// (8 u/s, not 9), and with that spent it does nothing.
#[test]
def test_coyote_jump_expires : Bool :=
    let s : MoState := mo_velocity tune (mo_with_air_used (airborne_for 0.15) 1) (intent 0.0 0.0 true true false false) 0.0 in
    let a : MoState := mo_velocity tune (airborne_for 0.15) (intent 0.0 0.0 true true false false) 0.0 in
    let v : Vec3 := mo_vel s in
    let va : Vec3 := mo_vel a in
    v.y < 0.0 && near 0.01 va.y 8.0 && mo_air_used a == 1

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
    // Falling from 0.3 above the floor, the air jump spent, jump pressed 2
    // frames before contact.
    let falling : MoState := mo_with_air_used (mo_with_vel mo_airborne (vec3 0.0 (0.0 - 3.0) 0.0)) 1 in
    let a : MoStep := mo_step tune floor Option.none falling (vec3 0.0 (mo_stand + 0.1) 0.0) (intent 0.0 0.0 true true false false) dt in
    let b : MoStep := run (step_state a) (step_pos a) (intent 0.0 0.0 false true false false) 4 in
    let v : Vec3 := mo_vel (step_state b) in
    v.y > 5.0

/// Highest feet height above the floor over `n` frames of intent `i`.
#[terminating]
def run_top (s : MoState) (p : Vec3) (i : Intent) (top : F64) (n : I64) : F64 :=
    if n <= 0 then top
    else
        let st : MoStep := mo_step tune floor Option.none s p i dt in
        let q : Vec3 := step_pos st in
        let h : F64 := q.y - mo_stand in
        run_top (step_state st) q i (if h > top then h else top) (n - 1)

/// A press buffered in the air and RELEASED before the landing still gives
/// a full short hop (it used to be cut on the jump's first frame).
#[test]
def test_buffered_press_released_before_landing_still_hops : Bool :=
    let falling : MoState := mo_with_air_used (mo_with_vel mo_airborne (vec3 0.0 (0.0 - 3.0) 0.0)) 1 in
    let a : MoStep := mo_step tune floor Option.none falling (vec3 0.0 (mo_stand + 0.1) 0.0) (intent 0.0 0.0 true false false false) dt in
    run_top (step_state a) (step_pos a) intent_none 0.0 90 > 1.0

#[test]
def test_landing_gives_back_the_air_jump : Bool :=
    let falling : MoState := mo_with_air_used (mo_with_vel mo_airborne (vec3 0.0 (0.0 - 3.0) 0.0)) 1 in
    let b : MoStep := run falling (vec3 0.0 (mo_stand + 0.1) 0.0) intent_none 10 in
    mo_grounded (step_state b) && mo_air_used (step_state b) == 0

/// Two boxes meeting at z = 0 (a seam), the far one `rise` higher.
def seam (rise : F64) : Scene :=
    scene_of [ entry_new (entity_new 1u64 0u64) (collider (shape_box (vec3 3.0 0.5 3.0))) (pose_at (vec3 0.0 (0.0 - 0.5) 3.0)),
               entry_new (entity_new 2u64 0u64) (collider (shape_box (vec3 3.0 0.5 3.0))) (pose_at (vec3 0.0 (rise - 0.5) (0.0 - 3.0))) ]

/// Running -z across `sc` at step `h` for `n` frames: is Mo grounded on
/// every frame? (Lost ground for longer than coyote time drops a jump.)
#[terminating]
def stays_grounded (sc : Scene) (s : MoState) (p : Vec3) (h : F64) (n : I64) : Bool :=
    if n <= 0 then true
    else
        let st : MoStep := mo_step tune sc Option.none s p (intent 0.0 (0.0 - 1.0) false false false false) h in
        if Bool.not (mo_grounded (step_state st)) then false
        else stays_grounded sc (step_state st) (step_pos st) h (n - 1)

def seam_ok (rise : F64) (h : F64) : Bool :=
    // From z = 5 for 0.85 s at up to run speed: across the seam, short of z = -6.
    stays_grounded (seam rise) mo_rest (vec3 0.0 (mo_stand + 0.01) 5.0) h (trunc_i64 (0.85 / h))

#[test]
def test_grounded_across_a_flat_seam : Bool :=
    seam_ok 0.0 (1.0 / 30.0) && seam_ok 0.0 (1.0 / 60.0) && seam_ok 0.0 (1.0 / 144.0)

#[test]
def test_grounded_up_a_small_step : Bool :=
    seam_ok 0.2 (1.0 / 30.0) && seam_ok 0.2 (1.0 / 60.0) && seam_ok 0.2 (1.0 / 144.0)

// ── Level reachability ──────────────────────────────────────────────

/// Horizontal distance a jump at run speed covers before falling back to
/// `dy` above its start (by the same integrator Mo uses).
/// `act` decides the presses: `act_dash` dashes at the top of the jump,
/// `act_double` air-jumps there, `act_double_dash` air-jumps and then
/// dashes at the top of the second jump (as the autopilot does).
#[terminating]
def reach_go (s : MoState) (x : F64) (y : F64) (dy : F64) (act : I64) (n : I64) : F64 :=
    if n > 400 then x
    else
        let v0 : Vec3 := mo_vel s in
        let air : Bool := act == act_double || act == act_double_dash in
        let again : Bool := air && n > 0 && v0.y <= 0.0 && mo_air_used s == 0 in
        let dash_ready : Bool := if act == act_double_dash then mo_air_used s >= 1 else act == act_dash in
        let dashing : Bool := dash_ready && n > 0 && v0.y <= 1.0 && Bool.not (mo_dashed s) in
        let s1 : MoState := mo_velocity tune s (intent 0.0 (0.0 - 1.0) (n == 0 || again) true dashing false) dt in
        let v : Vec3 := mo_vel s1 in
        let x1 : F64 := x - v.z * dt in
        let y1 : F64 := y + v.y * dt in
        if v.y < 0.0 && y1 < dy then x1 else reach_go s1 x1 y1 dy act (n + 1)

def reach_by (dy : F64) (act : I64) : F64 :=
    reach_go (mo_with_vel mo_rest (vec3 0.0 0.0 (0.0 - 7.0))) 0.0 0.0 dy act 0

def reach (dy : F64) (dash : Bool) : F64 := reach_by dy (if dash then act_dash else act_walk)

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

/// The tallest rise `act` clears.
def rise_limit (act : I64) : F64 := if act == act_double || act == act_double_dash then 2.6 else 1.5

/// How much of an action's simulated reach a gap may use: 80%, but 90% for
/// the air jump + dash, the hardest move, which a level uses on purpose for
/// one gap just past a plain double jump.
def margin (act : I64) : F64 := if act == act_double_dash then 0.9 else 0.8

/// Every consecutive pair of platforms (a mover leaves from its far end)
/// is within `margin` of the reach of the action `acts` names for it.
#[terminating]
def gaps_acts (ps : List Plat) (acts : List I64) : Bool :=
    match ps {
        List.empty => true,
        List.cons a0 rest =>
            match List.first rest {
                Option.none => true,
                Option.some b0 =>
                    match acts {
                        List.empty => false,
                        List.cons act more =>
                            let a : Plat := plat_at_end a0 in
                            let b : Plat := b0 in
                            let dy : F64 := plat_top b - plat_top a in
                            edge_gap a b <= margin act * reach_by dy act && dy <= rise_limit act && gaps_acts rest more
                    }
            }
    }

/// The gap from platform `i` to `i + 1` of `lv`, beyond `act`'s reach.
def needs_more_than (lv : Level) (i : I64) (act : I64) : Bool :=
    match List.get i (level_plats lv) {
        Option.some a0 =>
            match List.get (i + 1) (level_plats lv) {
                Option.some b0 =>
                    let a : Plat := a0 in
                    let b : Plat := b0 in
                    edge_gap a b > reach_by (plat_top b - plat_top a) act || plat_top b - plat_top a > 1.62,
                Option.none => false
            },
        Option.none => false
    }

#[test]
def test_every_cloud_steps_gap_is_reachable : Bool :=
    gaps_acts (level_plats cloud_steps) [act_double, act_double, act_walk, act_double, act_double_dash, act_walk]

#[test]
def test_cloud_steps_needs_the_air_jump_and_the_dash : Bool :=
    needs_more_than cloud_steps 0 act_walk && needs_more_than cloud_steps 1 act_walk
        && needs_more_than cloud_steps 4 act_double

#[test]
def test_every_drift_docks_gap_is_reachable : Bool :=
    gaps_acts (level_plats drift_docks) [act_walk, act_walk, act_walk, act_walk, act_walk, act_walk]

#[test]
def test_every_sun_spire_gap_is_reachable : Bool :=
    gaps_acts (level_plats sun_spire) [act_walk, act_double, act_walk, act_walk, act_walk, act_dash, act_double]

#[test]
def test_air_jump_reaches_further : Bool :=
    reach_by 0.0 act_double > reach 0.0 false + 1.5 && reach_by 0.0 act_double_dash > reach_by 0.0 act_double + 1.0

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

// ── New levels, movers, the campaign ────────────────────────────────

def bot_clears (lv : Level) (limit : I64) : Bool :=
    let a : App := mo_venture_autopilot lv in
    let r : Run := play a (app_initial_world a) 0 limit in
    let g : GameState := game_of r.world in
    game_won g && game_falls g == 0 && game_checkpoint g == 2

#[test]
def test_bot_finishes_cloud_steps : Bool := bot_clears cloud_steps 3600

#[test]
def test_bot_finishes_drift_docks : Bool := bot_clears drift_docks 6000

#[test]
def test_bot_finishes_sun_spire : Bool := bot_clears sun_spire 6000

/// Mo standing on a ferry is carried with it: after 4 s the ferry is at its
/// far end, 6 along +x, and Mo with it.
#[test]
def test_a_moving_platform_carries_mo : Bool :=
    let lv : Level := level_new "Ferry"
        [ plat 0.0 (0.0 - 0.5) 3.0 2.0 0.5 2.0 kind_grass,
          mover 0.0 (0.0 - 0.25) (0.0 - 3.0) 1.5 0.25 1.5 kind_wood 6.0 (0.0 - 0.25) (0.0 - 3.0) ]
        [] [] (vec3 0.0 0.0 20.0) (vec3 0.0 0.0 (0.0 - 3.0)) (0.0 - 8.0) [] in
    let a : App := mo_venture_on lv in
    let r : Run := play a (app_initial_world a) 0 240 in
    match find_mo r.world {
        Option.some e =>
            let p : Vec3 := mo_position r.world e in
            near 0.3 p.x 6.0 && near 0.05 p.y (mo_stand + 0.01) && game_falls (game_of r.world) == 0,
        Option.none => false
    }

#[terminating]
def play_to_level (a : App) (w : World) (n : I64) (limit : I64) (want : I64) : Run :=
    if n >= limit || world_level_index w == want then { world := w, frames := n : Run }
    else play_to_level a (frame_world (app_frame_dt a w dt)) (n + 1) limit want

/// After the goal the autopilot goes on to the next level, which starts
/// fresh: Mo back at the start, no sparks yet.
#[test]
def test_the_campaign_moves_on_after_the_goal : Bool :=
    let a : App := mo_venture_levels_autopilot [tiny_level, tiny_level] in
    let r : Run := play_to_level a (app_initial_world a) 0 1500 1 in
    let g : GameState := game_of (frame_world (app_frame_dt a r.world dt)) in
    world_level_index r.world == 1 && Bool.not (game_won g) && game_sparks g == 0

#[test]
def test_the_game_has_a_shadowing_sun : Bool :=
    let a : App := mo_venture_on tiny_level in
    light_shadows (world_light (app_initial_world a))

// ── Xiaozhu and Xiaomao ─────────────────────────────────────────────

/// One frame with `code` freshly pressed.
def press_key (a : App) (w : World) (code : String) : World :=
    frame_world (app_frame_dt a (world_set_input w (input_apply input_empty (input_key_down code))) dt)

def mo_parts (w : World) : I64 :=
    match find_mo w {
        Option.some e => List.length (children_of w e),
        Option.none => 0 - 1
    }

def mo_z (w : World) : F64 :=
    match find_mo w {
        Option.some e => let p : Vec3 := mo_position w e in p.z,
        Option.none => 0.0 - 99.0
    }

/// Mo starts as Xiaozhu the piggy (12 parts) and shows it on the HUD.
#[test]
def test_mo_starts_as_xiaozhu : Bool :=
    let a : App := mo_venture_on tiny_level in
    let r : Run := play a (app_initial_world a) 0 2 in
    world_hero r.world == hero_xiaozhu && mo_parts r.world == 12 && is_text (hud_get r.world "hero") (hero_name hero_xiaozhu)

/// C turns Mo into Xiaomao the kitty (15 parts) in place, and back.
#[test]
def test_c_switches_between_piggy_and_kitty_in_place : Bool :=
    let a : App := mo_venture_on tiny_level in
    let r : Run := play a (app_initial_world a) 0 30 in
    let z0 : F64 := mo_z r.world in
    let w1 : World := press_key a r.world "KeyC" in
    let kitty : Bool := world_hero w1 == hero_xiaomao && mo_parts w1 == 15 && near 0.02 (mo_z w1) z0
                        && is_text (hud_get w1 "hero") "Xiaomao Mo" in
    let w2 : World := press_key a w1 "KeyC" in
    kitty && world_hero w2 == hero_xiaozhu && mo_parts w2 == 12

/// The hero stays chosen across a level change.
#[test]
def test_the_hero_survives_a_level_change : Bool :=
    let a : App := mo_venture_levels [tiny_level, tiny_level] in
    let w1 : World := press_key a (app_initial_world a) "KeyC" in
    let w2 : World := press_key a w1 "Digit2" in
    world_level_index w2 == 1 && world_hero w2 == hero_xiaomao && mo_parts w2 == 15
