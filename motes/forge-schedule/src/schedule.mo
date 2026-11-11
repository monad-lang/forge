// forge-schedule: the `Schedule` builder, stage execution, and `Time`.
//
// Systems run in REGISTRATION order within a stage -- correctness first. The
// conflict-based `batches` from `system.mo` are exposed as metadata
// (`stage_batches`) for the Phase 7 executor, which is where running a batch
// concurrently on fibers actually happens. A pure `World -> World` schedule
// must not reorder systems, because a later system may legitimately depend on
// an earlier one's side effect even with no declared read/write overlap.

use std::list {List.filter}
use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {
    World, Spawned, spawn, empty_world, world_entity_count, world_clock
}
use forge_core::commands {CommandBuffer, empty_buffer, flush}
use forge_core::world_m {WorldM, PureWorld, PureWorld.run}
use init::id {Id}
use lib::system {
    ScheduleState, start_s, update_s, fixed_update_s, render_s, cleanup_s,
    all_stages, System, system_new, system_run, system_in_stage,
    Clock, clock_advance, system_noop, batches
}

// ── Test systems ────────────────────────────────────────────────────

/// One `WorldM` action, hoisted out of the systems that run it: an inline
/// `[Constraint]`-bearing call used as an argument miscompiles (PLAN.md's
/// "Verified parser / API gotchas").
def spawn_pos (w : World) : World :=
    let s : Spawned := spawn w [Pair.pair "pos" (Any.any 1u64)] in
    s.world

/// A system body that spawns one entity.
def spawn_one : WorldM Id Unit := WorldM.modify spawn_pos

// ── Schedule ────────────────────────────────────────────────────────

/// An ordered collection of systems. Non-`Copy` by construction (`List`), so it
/// carries a hand-written identity `Copy`: the list is immutable and shared, and
/// the handle is read several times during a run.
#[derive Debug]
pub struct Schedule {
    systems : List System
}

pub instance Copy Schedule {
    def copy (s : Schedule) : Pair Schedule Schedule := Pair.pair s s
}

pub def empty_schedule : Schedule := { systems := [] : Schedule }

/// Append a system (it runs in its own declared stage).
pub def add_system (sch : Schedule) (s : System) : Schedule :=
    { systems := List.append sch.systems [s] : Schedule }

/// Append a system that runs in `st` (overriding whatever stage it carried).
pub def add_system_to (sch : Schedule) (st : ScheduleState) (s : System) : Schedule :=
    add_system sch { s with stage := st }

pub def schedule_systems (sch : Schedule) : List System := sch.systems

pub def schedule_len (sch : Schedule) : I64 := List.length sch.systems

/// The systems registered for `st`, in registration order.
pub def systems_in_stage (sch : Schedule) (st : ScheduleState) : List System :=
    List.filter (fn (s : System) => system_in_stage s st) sch.systems

pub def stage_system_count (sch : Schedule) (st : ScheduleState) : I64 :=
    List.length (systems_in_stage sch st)

/// The conflict batches for `st` (metadata for a concurrent executor).
pub def stage_batches (sch : Schedule) (st : ScheduleState) : List (List System) :=
    batches (systems_in_stage sch st)

// ── Running ─────────────────────────────────────────────────────────

/// Run one system against the world. `PureWorld.run` consumes a `WorldM Id A`.
#[terminating]
def run_systems_go (world : World) (systems : List System) : World :=
    match systems {
        List.empty => world,
        List.cons s rest =>
            let m : WorldM Id Unit := system_run s in
            let out : Pair World Unit := PureWorld.run m world in
            run_systems_go out.first rest
    }

/// Run `systems` in order, threading the world.
pub def run_systems (world : World) (systems : List System) : World :=
    run_systems_go world systems

/// Run one stage's systems, in registration order.
pub def run_stage (world : World) (sch : Schedule) (st : ScheduleState) : World :=
    run_systems world (systems_in_stage sch st)

/// Run every stage of the pipeline in order, flushing `buffer` at the first
/// stage boundary. (A pure schedule has no way for a system to *enqueue* a
/// command -- that needs the `Commands` handle the `WorldM IO` app carries,
/// Phase 7 -- so the buffer is a one-shot input here, and the stage boundaries
/// are where Phase 7 will flush instead.)
#[terminating]
def run_stages_go
    (world : World) (sch : Schedule) (stages : List ScheduleState) (buffer : CommandBuffer)
    : World :=
    match stages {
        List.empty => world,
        List.cons st rest =>
            let after : World := run_stage world sch st in
            let flushed : World := flush after buffer in
            run_stages_go flushed sch rest empty_buffer
    }

/// The whole schedule once, from `world`.
pub def run_schedule (world : World) (sch : Schedule) (buffer : CommandBuffer) : World :=
    run_stages_go world sch all_stages buffer

/// The whole schedule once, with no deferred commands.
pub def run_schedule_pure (world : World) (sch : Schedule) : World :=
    run_schedule world sch empty_buffer

/// Run the `fixed_update_s` stage `n` times -- what a fixed-timestep frame does
/// with `clock_advance`'s step count.
#[terminating]
def run_fixed_go (world : World) (sch : Schedule) (n : I64) : World :=
    if I64.lt 0 n
    then run_fixed_go (run_stage world sch fixed_update_s) sch (I64.sub n 1)
    else world

pub def run_fixed_steps (world : World) (sch : Schedule) (n : I64) : World :=
    run_fixed_go world sch n

// ── Time ────────────────────────────────────────────────────────────

/// The frame clock resource: elapsed wall time, the last delta, the fixed step,
/// the leftover accumulator, and how many fixed steps the last advance asked
/// for.
#[derive Copy Clone Debug]
pub struct Time {
    elapsed : F64,
    delta : F64,
    fixed_delta : F64,
    accumulator : F64,
    fixed_steps : I64
}

pub def time_new (fixed_delta : F64) : Time :=
    { elapsed := 0.0, delta := 0.0, fixed_delta := fixed_delta,
      accumulator := 0.0, fixed_steps := 0
      : Time }

/// Advance the clock by `dt`; `fixed_steps` is what the fixed stage should run.
pub def time_advance (t : Time) (dt : F64) : Time :=
    let c : Clock := { accumulator := t.accumulator, fixed_delta := t.fixed_delta : Clock } in
    let s := clock_advance c dt in
    { elapsed := t.elapsed + dt,
      delta := dt,
      fixed_delta := t.fixed_delta,
      accumulator := s.clock.accumulator,
      fixed_steps := s.steps
      : Time }

pub def time_elapsed (t : Time) : F64 := t.elapsed

pub def time_delta (t : Time) : F64 := t.delta

pub def time_fixed_steps (t : Time) : I64 := t.fixed_steps

pub def time_accumulator (t : Time) : F64 := t.accumulator

#[test]
def test_empty_schedule_runs_nothing : Bool :=
    U64.beq (world_clock (run_schedule_pure empty_world empty_schedule)) 0u64

#[test]
def test_add_system_then_count_stage : Bool :=
    let sch : Schedule := add_system empty_schedule (system_new "s" update_s [] [] system_noop) in
    I64.beq (stage_system_count sch update_s) 1

#[test]
def test_add_system_to_overrides_stage : Bool :=
    let sch : Schedule :=
        add_system_to empty_schedule render_s (system_new "s" update_s [] [] system_noop) in
    I64.beq (stage_system_count sch render_s) 1
        && I64.beq (stage_system_count sch update_s) 0

#[test]
def test_run_schedule_runs_a_system : Bool :=
    let sch : Schedule := add_system empty_schedule (system_new "spawn" update_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 1

#[test]
def test_systems_run_in_registration_order_within_a_stage : Bool :=
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_new "a" update_s [] [] spawn_one))
                   (system_new "b" update_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 2

#[test]
def test_system_in_a_later_stage_still_runs : Bool :=
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_new "a" start_s [] [] spawn_one))
                   (system_new "b" cleanup_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 2

#[test]
def test_fixed_steps_repeat_the_fixed_stage : Bool :=
    let sch : Schedule :=
        add_system empty_schedule (system_new "fixed" fixed_update_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_fixed_steps empty_world sch 3)) 3

#[test]
def test_fixed_steps_ignored_by_a_plain_run : Bool :=
    let sch : Schedule :=
        add_system empty_schedule (system_new "fixed" fixed_update_s [] [] spawn_one) in
    I64.beq (world_entity_count (run_schedule_pure empty_world sch)) 1

#[test]
def test_stage_batches_metadata : Bool :=
    let sch : Schedule :=
        add_system (add_system empty_schedule (system_new "a" update_s [] [1] system_noop))
                   (system_new "b" update_s [] [1] system_noop) in
    I64.beq (List.length (stage_batches sch update_s)) 2

#[test]
def test_time_first_advance_below_step : Bool :=
    let t : Time := time_advance (time_new 0.1) 0.05 in
    I64.beq (time_fixed_steps t) 0

#[test]
def test_time_advance_accumulates : Bool :=
    let t1 : Time := time_advance (time_new 0.1) 0.06 in
    let t2 : Time := time_advance t1 0.06 in
    I64.beq (time_fixed_steps t2) 1

#[test]
def test_time_elapsed_grows : Bool :=
    let t1 : Time := time_advance (time_new 0.1) 0.25 in
    let t2 : Time := time_advance t1 0.25 in
    time_elapsed t2 > 0.4999 && time_elapsed t2 < 0.5001
