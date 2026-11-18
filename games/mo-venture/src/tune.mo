// Mo Venture: every number that shapes how Mo moves, in one place. The
// level's reachability test and the controller read the same values, so a
// change here that makes a gap too wide fails a test instead of a playtest.

use std::derive {}

/// Movement tuning. `Copy`.
#[derive Copy Clone]
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
    turn_rate : F64
}

/// The game's tuning:
/// - a jump reaches 9^2 / (2 * 25) = 1.62 units and lasts 0.72 s on the flat;
/// - running is 7 u/s (10 with Shift on the ground), reached in about 0.25 s;
/// - releasing Space early halves the rising speed (a short hop);
/// - a jump still works 0.1 s after leaving a ledge (coyote time), and a
///   press up to 0.12 s before landing is kept (jump buffer);
/// - one air dash per jump: 13 u/s along Mo's facing plus a small lift.
pub def tune : Tune :=
    { gravity := 25.0, jump_speed := 9.0, jump_cut := 0.5, run_speed := 7.0, sprint_speed := 10.0,
      ground_accel := 30.0, ground_friction := 40.0, air_accel := 12.0,
      coyote := 0.1, buffer := 0.12, dash_speed := 13.0, dash_lift := 3.0, max_fall := 20.0,
      turn_rate := 12.0
      : Tune }

/// Mo's collider: a capsule of radius 0.35 around a 0.7 segment, so 1.4
/// tall; its centre stands 0.7 above the ground.
pub def mo_radius : F64 := 0.35

pub def mo_half_height : F64 := 0.35

pub def mo_stand : F64 := 0.7
