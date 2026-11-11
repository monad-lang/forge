// forge-schedule integration tests, over the PUBLIC surface (`lib::{...}`).
//
// The in-file unit tests cover each module; these drive the whole pipeline the
// way the app will: build a schedule out of `WorldM` systems, run it for
// frames, and advance the `Time` resource.

use lib::{
    ScheduleState, update_s, fixed_update_s, render_s, start_s, cleanup_s,
    stage_name, all_stages,
    System, system_new, system_pure, system_stage_ordinal, system_noop,
    system_in_stage, schedule_len, systems_in_stage, stage_system_count,
    Schedule, empty_schedule, add_system, add_system_to, run_schedule_pure,
    run_fixed_steps, run_stage, stage_batches,
    Time, time_new, time_advance, time_elapsed, time_fixed_steps
}
use forge_core::ecs {
    World, Spawned, spawn, empty_world, world_entity_count, despawn
}
use forge_core::world_m {WorldM}
use init::id {Id}

// ── Test systems, hoisted out of the `System` values that run them ──

def spawn_pos (w : World) : World :=
    let s : Spawned := spawn w [Pair.pair "pos" (Any.any 1u64)] in
    s.world

def spawn_one : WorldM Id Unit := WorldM.modify spawn_pos

/// Spawn, then immediately despawn the entity just created -- a system that
/// both adds and removes, to exercise a two-step `WorldM` computation.
def spawn_then_despawn_world (w : World) : World :=
    let s : Spawned := spawn w [Pair.pair "pos" (Any.any 1u64)] in
    despawn s.world s.entity

def spawn_then_despawn : WorldM Id Unit :=
    WorldM.modify spawn_then_despawn_world

#[test]
def test_pipeline_order_covers_every_stage : Bool :=
    I64.beq (List.length all_stages) 12

#[test]
def test_a_full_frame_spawns_once_per_spawning_system : Bool :=
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_new "a" update_s [] [] spawn_one))
                   (system_new "b" render_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 2

#[test]
def test_a_fixed_stage_system_runs_once_per_frame : Bool :=
    // A plain frame runs the fixed stage exactly once even when the clock asked
    // for more; a frame loop that uses `time_fixed_steps` runs it that many.
    let sch : Schedule :=
        add_system empty_schedule (system_new "fixed" fixed_update_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 1

#[test]
def test_a_system_that_spawns_and_despawns_leaves_no_entities : Bool :=
    let sch : Schedule :=
        add_system empty_schedule (system_new "churn" update_s [] [] spawn_then_despawn) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 0

#[test]
def test_frame_loop_accumulates_fixed_steps : Bool :=
    let sch : Schedule :=
        add_system empty_schedule (system_new "fixed" fixed_update_s [] [] spawn_one) in
    let t0 : Time := time_new 0.1 in
    // 0.35s at a 0.1s fixed step asks for 3 steps.
    let t1 : Time := time_advance t0 0.35 in
    I64.beq (time_fixed_steps t1) 3
        && I64.beq (world_entity_count (run_fixed_steps empty_world sch (time_fixed_steps t1))) 3

#[test]
def test_time_advances_over_many_frames : Bool :=
    let t1 : Time := time_advance (time_new 0.1) 0.06 in
    let t2 : Time := time_advance t1 0.06 in
    let t3 : Time := time_advance t2 0.06 in
    // 0.18s total at a 0.1s step: exactly one fixed step fires, on t2.
    time_elapsed t3 > 0.1799 && time_elapsed t3 < 0.1801
        && I64.beq (time_fixed_steps t1) 0
        && I64.beq (time_fixed_steps t2) 1
        && I64.beq (time_fixed_steps t3) 0

#[test]
def test_add_system_to_places_in_the_named_stage : Bool :=
    let s : System := system_pure "s" start_s system_noop in
    let sch : Schedule := add_system_to empty_schedule cleanup_s s in
    I64.beq (stage_system_count sch cleanup_s) 1
        && I64.beq (stage_system_count sch start_s) 0

#[test]
def test_registration_order_is_preserved_in_a_stage : Bool :=
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_pure "first" update_s system_noop))
                   (system_pure "second" update_s system_noop) in
    let names : List String := List.map (fn (s : System) => s.name) (systems_in_stage sch update_s) in
    match List.first names {
        Option.some n => String.beq n "first",
        Option.none => false
    }

#[test]
def test_stage_name_round_trips_through_the_enum : Bool :=
    String.beq (stage_name update_s) "update" && String.beq (stage_name start_s) "start"

#[test]
def test_batches_are_metadata_not_execution_order : Bool :=
    // Two conflicting writers: two batches, but a plain run still executes both
    // (sequentially) -- batching never drops a system.
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_new "a" update_s [] [1] spawn_one))
                   (system_new "b" update_s [] [1] spawn_one) in
    I64.beq (List.length (stage_batches sch update_s)) 2
        && I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 2

#[test]
def test_run_stage_runs_only_that_stage : Bool :=
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_new "u" update_s [] [] spawn_one))
                   (system_new "r" render_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_stage empty_world sch update_s)) 1
