// Mo Venture: every number that shapes how Mo moves, in one place. The
// level's reachability test and the controller read the same values, so a
// change here that makes a gap too wide fails a test instead of a playtest.

use std::derive {}

/// Movement tuning. `Copy`.
pub struct Tune {
    gravity : F64,
    jump_speed : F64,
    jump_cut : F64,
    run_speed : F64,
    sprint_speed : F64,
    ground_accel : F64,
    ground_friction : F64,
    air_accel : F64,
    coyote : F64,
    buffer : F64,
    dash_speed : F64,
    dash_lift : F64,
    max_fall : F64,
    turn_rate : F64,
    min_hop : F64,
    air_jumps : I64,
    air_jump_speed : F64,
    climb_speed : F64,
    slam_speed : F64,
    slam_timeout : F64,
    slam_radius : F64,
    spin_time : F64,
    spin_radius : F64,
    leash_distance : F64,
    leash_height : F64,
    leash_delay : I64,
    leash_cooldown : I64,
    follow_behind : F64,
    follow_side : F64,
    follow_start : F64,
    follow_stop : F64,
    follow_sprint : F64
}

pub instance Copy Tune {
    def copy (t : Tune) : Pair Tune Tune := Pair.pair t t
}

/// The game's tuning:
/// - a jump reaches 9^2 / (2 * 25) = 1.62 units and lasts 0.72 s on the flat;
/// - running is 7 u/s (10 with Shift on the ground), reached in about 0.25 s;
/// - releasing Space early halves the rising speed (a short hop), but never
///   before 0.12 s of rise, so a tap (down and up inside one frame) or a
///   buffered press released before landing still hops about 1.1 units;
/// - one mid-air jump per airtime (Space again in the air): 8 u/s up, a
///   further 1.28 units from where it starts;
/// - a jump still works 0.1 s after leaving a ledge (coyote time), and a
///   press up to 0.12 s before landing is kept (jump buffer);
/// - one air dash per jump: 13 u/s along Mo's facing plus a small lift;
/// - the companion stands 2.6 behind (toward the camera) and 2.2 to its
///   right, starts walking at 2.4 and stops at 0.9 (the dead zone is what
///   keeps it from jittering), and is leashed back only after 12 frames of
///   being stranded, at most once every 90 frames (1.5 s).
pub def tune : Tune :=
    { gravity := 25.0, jump_speed := 9.0, jump_cut := 0.5, run_speed := 7.0, sprint_speed := 10.0,
      ground_accel := 30.0, ground_friction := 40.0, air_accel := 12.0,
      coyote := 0.1, buffer := 0.12, dash_speed := 13.0, dash_lift := 3.0, max_fall := 20.0,
      turn_rate := 12.0, min_hop := 0.12, air_jumps := 1, air_jump_speed := 8.0,
      climb_speed := 3.2, slam_speed := 24.0, slam_timeout := 3.0, slam_radius := 1.6,
      spin_time := 0.45, spin_radius := 1.5,
      leash_distance := 12.0, leash_height := 3.0, leash_delay := 12, leash_cooldown := 90,
      follow_behind := 2.6, follow_side := 2.2, follow_start := 2.4, follow_stop := 0.9,
      follow_sprint := 6.5
      : Tune }

/// Mo's collider: a capsule of radius 0.35 around a 0.7 segment, so 1.4
/// tall; its centre stands 0.7 above the ground.
pub def mo_radius : F64 := 0.35

pub def mo_half_height : F64 := 0.35

pub def mo_stand : F64 := 0.7
