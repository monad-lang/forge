// Mo Venture: the levels after the Skyway, as data, and the campaign order.
//
// Each level teaches one thing and the last one mixes them:
//
// - Cloud Steps: the mid-air jump. Ledges too tall and gaps too wide for
//   one jump, and one gap that needs the air jump AND the dash.
// - Drift Docks: moving platforms. A shuttle, an elevator and a sideways
//   ferry over the void; wait for one, ride it, step off.
// - Sun Spire: a climb that uses all of it: a double-jump ledge, an
//   elevator, a dash gap and a last double jump to the goal.
//
// Platform lists run in route order (the reachability tests walk them
// pairwise), and each route marks how its spot is reached.

use forge_math {Vec3, vec3}
use lib::level {
    Level, level_new, Plat, plat, mover, Way, way, n, kind_grass, kind_stone, kind_wood, kind_gold,
    act_walk, act_jump, act_dash, act_double, act_double_dash, act_wait, act_ride, skyway
}

// ── Cloud Steps ─────────────────────────────────────────────────────

/// Tops: 0, 2.4 (a double-jump ledge), 2.4 past a 5.5 gap, 3.6, 5.8 (another
/// tall ledge), 5.8 past a 9.0 gap (beyond a double jump's ~8.0: it takes the
/// air jump AND the dash, ~10.3), 5.8 for the goal.
def cloud_plats : List Plat :=
    [ plat 0.0 (n 0.5) 0.0 3.0 0.5 3.0 kind_grass,          // start, z -3..3
      plat 0.0 1.9 (n 6.5) 2.5 0.5 2.5 kind_stone,          // top 2.4, z -9..-4
      plat 0.0 1.9 (n 17.0) 2.5 0.5 2.5 kind_grass,         // checkpoint 1, z -19.5..-14.5
      plat 0.0 3.1 (n 22.5) 2.0 0.5 1.5 kind_stone,         // top 3.6, z -24..-21
      plat 0.0 5.3 (n 27.5) 2.5 0.5 2.0 kind_stone,         // top 5.8, z -29.5..-25.5
      plat 0.0 5.3 (n 41.0) 2.5 0.5 2.5 kind_grass,         // checkpoint 2, z -43.5..-38.5
      plat 0.0 5.3 (n 49.0) 2.5 0.5 2.5 kind_gold ]         // goal, z -51.5..-46.5

def cloud_sparks : List Vec3 :=
    [ vec3 0.0 0.7 (n 1.5), vec3 0.0 3.1 (n 6.5), vec3 0.0 4.2 (n 12.0), vec3 0.0 3.1 (n 17.0),
      vec3 0.0 4.3 (n 22.5), vec3 0.0 6.5 (n 27.5), vec3 0.0 7.6 (n 34.0), vec3 0.0 6.5 (n 41.0),
      vec3 0.0 6.5 (n 47.0) ]

def cloud_route : List Way :=
    [ way 0.0 2.4 (n 6.5) act_double,
      way 0.0 2.4 (n 17.0) act_double,
      way 0.0 3.6 (n 22.5) act_walk,
      way 0.0 5.8 (n 27.5) act_double,
      way 0.0 5.8 (n 41.0) act_double_dash,
      way 0.0 5.8 (n 49.0) act_walk ]

pub def cloud_steps : Level :=
    level_new "Cloud Steps" cloud_plats cloud_sparks [vec3 0.0 2.4 (n 17.0), vec3 0.0 5.8 (n 41.0)]
              (vec3 0.0 5.8 (n 49.0)) (vec3 0.0 0.0 1.5) (n 8.0) cloud_route

// ── Drift Docks ─────────────────────────────────────────────────────

/// All tops at 0 until the elevator lifts Mo to 4.0. Movers rest
/// `mover_dwell` s at each end.
def docks_plats : List Plat :=
    [ plat 0.0 (n 0.5) 0.0 3.0 0.5 3.0 kind_grass,                                 // start, z -3..3
      mover 0.0 (n 0.25) (n 6.0) 1.5 0.25 1.5 kind_wood 0.0 (n 0.25) (n 14.0),     // shuttle along -z
      plat 0.0 (n 0.5) (n 20.0) 3.0 0.5 3.0 kind_grass,                            // checkpoint 1, z -23..-17
      mover 0.0 (n 0.25) (n 26.0) 1.5 0.25 1.5 kind_wood 0.0 3.75 (n 26.0),        // elevator, top 0 -> 4
      plat 0.0 3.5 (n 31.0) 2.5 0.5 2.0 kind_stone,                                // checkpoint 2, top 4, z -33..-29
      mover 0.0 3.75 (n 37.0) 1.5 0.25 1.5 kind_wood 6.0 3.75 (n 37.0),            // ferry along +x
      plat 6.0 3.5 (n 43.0) 2.5 0.5 2.5 kind_gold ]                                // goal, z -45.5..-40.5

def docks_sparks : List Vec3 :=
    [ vec3 0.0 0.7 (n 1.5), vec3 0.0 0.7 (n 18.5), vec3 0.0 0.7 (n 21.5), vec3 1.5 4.7 (n 31.0),
      vec3 (n 1.5) 4.7 (n 31.0), vec3 6.0 4.7 (n 42.0), vec3 6.0 4.7 (n 44.0) ]

def docks_route : List Way :=
    [ way 0.0 0.0 (n 6.0) act_wait,
      way 0.0 0.0 (n 14.0) act_ride,
      way 0.0 0.0 (n 20.0) act_walk,
      way 0.0 0.0 (n 26.0) act_wait,
      way 0.0 4.0 (n 26.0) act_ride,
      way 0.0 4.0 (n 31.0) act_walk,
      way 0.0 4.0 (n 37.0) act_wait,
      way 6.0 4.0 (n 37.0) act_ride,
      way 6.0 4.0 (n 43.0) act_walk ]

pub def drift_docks : Level :=
    level_new "Drift Docks" docks_plats docks_sparks [vec3 0.0 0.0 (n 20.0), vec3 0.0 4.0 (n 31.0)]
              (vec3 6.0 4.0 (n 43.0)) (vec3 0.0 0.0 1.5) (n 8.0) docks_route

// ── Sun Spire ───────────────────────────────────────────────────────

/// A step (1.2), a double-jump ledge (3.6), a turn to +x, an elevator to
/// 7.6, a dash gap, and a last double jump up to the goal at 8.6.
def spire_plats : List Plat :=
    [ plat 0.0 (n 0.5) 0.0 3.0 0.5 3.0 kind_grass,                                 // start, z -3..3
      plat 0.0 0.7 (n 5.0) 2.0 0.5 1.5 kind_stone,                                 // top 1.2, z -6.5..-3.5
      plat 0.0 3.1 (n 9.0) 2.0 0.5 1.5 kind_stone,                                 // checkpoint 1, top 3.6
      plat 4.5 3.1 (n 9.0) 1.5 0.5 1.5 kind_stone,                                 // x 3..6
      mover 9.0 3.35 (n 9.0) 1.5 0.25 1.5 kind_wood 9.0 7.35 (n 9.0),              // elevator, top 3.6 -> 7.6
      plat 9.0 7.1 (n 14.0) 2.0 0.5 2.0 kind_grass,                                // checkpoint 2, z -16..-12
      plat 9.0 7.1 (n 23.0) 2.0 0.5 2.0 kind_stone,                                // past the 5.0 dash gap
      plat 9.0 8.1 (n 33.0) 2.5 0.5 2.5 kind_gold ]                                // goal, top 8.6

def spire_sparks : List Vec3 :=
    [ vec3 0.0 0.7 (n 1.5), vec3 0.0 1.9 (n 5.0), vec3 0.0 4.3 (n 9.0), vec3 4.5 4.3 (n 9.0),
      vec3 9.0 8.3 (n 14.0), vec3 9.0 8.9 (n 18.5), vec3 9.0 8.3 (n 23.0), vec3 9.0 9.3 (n 33.0) ]

def spire_route : List Way :=
    [ way 0.0 1.2 (n 5.0) act_walk,
      way 0.0 3.6 (n 9.0) act_double,
      way 4.5 3.6 (n 9.0) act_walk,
      way 9.0 3.6 (n 9.0) act_wait,
      way 9.0 7.6 (n 9.0) act_ride,
      way 9.0 7.6 (n 14.0) act_walk,
      way 9.0 7.6 (n 23.0) act_dash,
      way 9.0 8.6 (n 33.0) act_double ]

pub def sun_spire : Level :=
    level_new "Sun Spire" spire_plats spire_sparks [vec3 0.0 3.6 (n 9.0), vec3 9.0 7.6 (n 14.0)]
              (vec3 9.0 8.6 (n 33.0)) (vec3 0.0 0.0 1.5) (n 8.0) spire_route

// ── The campaign ────────────────────────────────────────────────────

/// The levels in order.
pub def all_levels : List Level := [skyway, cloud_steps, drift_docks, sun_spire]
