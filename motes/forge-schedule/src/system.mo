// forge-schedule: stages, systems, and the fixed-timestep clock.
//
// A `System` carries a `WorldM Id Unit` computation. The plan's `WorldM IO`
// variant (and actually running systems in parallel on fibers) belongs to the
// app loop, Phase 7 -- everything here is a PURE `World -> World` schedule, so
// it runs (and is tested) inside `monad test` with no IO at all. The batching
// machinery is here and tested; Phase 7 only has to execute the batches.

use std::derive {}
use std::list {List.all, List.any}
// NOTE: deriving `Copy`/`Clone` needs the derive MACROS imported by name;
// an empty `use std::derive {}` does not supply them (it only does for a
// struct, where the `Copy`/`Clone` class names in scope substitute).
use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::world_m {WorldM}
use init::id {Id}
// ── Stages ──────────────────────────────────────────────────────────

/// The fixed pipeline order (all-nullary). `BEq` is deliberately NOT derived:
/// it would need `derive_beq`, and ordering is compared by `stage_ordinal`
/// (an `I64`) everywhere, so structural equality on the enum is never used.
#[derive Copy Clone Debug]
pub type ScheduleState {
    start_s,
    pre_init_s,
    init_s,
    first_s,
    pre_update_s,
    state_transition_s,
    fixed_update_s,
    update_s,
    post_update_s,
    last_s,
    render_s,
    cleanup_s
}

/// The stage's position in the pipeline (0 = first). Ordering is by this, not
/// by the declaration order of the constructors.
pub def stage_ordinal (s : ScheduleState) : I64 :=
    match s {
        start_s => 0,
        pre_init_s => 1,
        init_s => 2,
        first_s => 3,
        pre_update_s => 4,
        state_transition_s => 5,
        fixed_update_s => 6,
        update_s => 7,
        post_update_s => 8,
        last_s => 9,
        render_s => 10,
        cleanup_s => 11
    }

pub def stage_name (s : ScheduleState) : String :=
    match s {
        start_s => "start",
        pre_init_s => "pre_init",
        init_s => "init",
        first_s => "first",
        pre_update_s => "pre_update",
        state_transition_s => "state_transition",
        fixed_update_s => "fixed_update",
        update_s => "update",
        post_update_s => "post_update",
        last_s => "last",
        render_s => "render",
        cleanup_s => "cleanup"
    }

/// Every stage, in pipeline order.
pub def all_stages : List ScheduleState :=
    [start_s, pre_init_s, init_s, first_s, pre_update_s, state_transition_s,
     fixed_update_s, update_s, post_update_s, last_s, render_s, cleanup_s]

pub def stage_count : I64 := 12

// ── Systems ─────────────────────────────────────────────────────────

/// A registered system. `reads`/`writes` are INTERNED component ids (the
/// `ComponentId.id` from forge-core's registry), so conflict analysis is a few
/// integer compares.
///
/// Hand-written identity `Copy` rather than a derive: `run` is a `WorldM Id
/// Unit` (a closure), which has no `Copy` instance. Sharing the handle is sound
/// -- the computation is an immutable value, and the pure schedule never
/// mutates what it captures -- and it is what lets conflict analysis read a
/// system's `reads`/`writes`/`run` more than once.
#[derive Debug]
pub struct System {
    name : String,
    stage : ScheduleState,
    reads : List I64,
    writes : List I64,
    run : WorldM Id Unit
}

pub instance Copy System {
    def copy (s : System) : Pair System System := Pair.pair s s
}

pub def system_new (name : String) (stage : ScheduleState)
    (reads : List I64) (writes : List I64) (run : WorldM Id Unit) : System :=
    { name := name, stage := stage, reads := reads, writes := writes, run := run : System }

/// A system that reads nothing and writes nothing.
pub def system_pure (name : String) (stage : ScheduleState) (run : WorldM Id Unit) : System :=
    system_new name stage [] [] run

pub def system_name (s : System) : String := s.name

pub def system_stage (s : System) : ScheduleState := s.stage

pub def system_stage_ordinal (s : System) : I64 := stage_ordinal s.stage

pub def system_reads (s : System) : List I64 := s.reads

pub def system_writes (s : System) : List I64 := s.writes

pub def system_run (s : System) : WorldM Id Unit := s.run

pub def system_in_stage (s : System) (st : ScheduleState) : Bool :=
    I64.beq (system_stage_ordinal s) (stage_ordinal st)

/// A computation that does nothing -- the run value for a test system.
pub def system_noop : WorldM Id Unit := Monad.pure unit

// ── Conflict analysis / batching ────────────────────────────────────

/// Do the two id lists share an element?
pub def ids_overlap (a : List I64) (b : List I64) : Bool :=
    List.any (fn (x : I64) => List.any (fn (y : I64) => I64.beq x y) b) a

/// Do two systems conflict? They do if one writes anything the other reads or
/// writes. Two systems that only read the same component do NOT conflict and
/// may run in the same batch.
pub def systems_conflict (a : System) (b : System) : Bool :=
    ids_overlap (system_writes a) (system_writes b)
        || ids_overlap (system_writes a) (system_reads b)
        || ids_overlap (system_reads a) (system_writes b)

/// Can `s` join `batch` (conflicts with nothing already in it)?
def fits_batch (s : System) (batch : List System) : Bool :=
    List.all (fn (o : System) => Bool.not (systems_conflict s o)) batch

/// Greedy: put `s` in the first batch it fits, else open a new one. Preserves
/// registration order within a batch.
#[terminating]
def place_in_batch (s : System) (batches : List (List System)) : List (List System) :=
    match batches {
        List.empty => [List.cons s []],
        List.cons b rest =>
            if fits_batch s b
            then List.cons (List.cons s b) rest
            else List.cons b (place_in_batch s rest)
    }

#[terminating]
def batches_go (systems : List System) (acc : List (List System)) : List (List System) :=
    match systems {
        List.empty => acc,
        List.cons s rest => batches_go rest (place_in_batch s acc)
    }

/// Partition `systems` into batches that may each run concurrently.
#[terminating]
pub def batches (systems : List System) : List (List System) :=
    batches_go systems []

pub def batch_count (systems : List System) : I64 := List.length (batches systems)

// ── Fixed timestep ──────────────────────────────────────────────────

/// Accumulator + fixed step, the standard "fixed timestep" clock.
#[derive Copy Clone Debug]
pub struct Clock {
    accumulator : F64,
    fixed_delta : F64
}

pub def clock_new (fixed_delta : F64) : Clock :=
    { accumulator := 0.0, fixed_delta := fixed_delta : Clock }

/// The leftover accumulator and the number of fixed steps it produced.
#[derive Copy Clone Debug]
pub struct Drained {
    leftover : F64,
    steps : I64
}

/// Drain whole `delta`s out of `acc`, counting them. No int->float conversion
/// is needed (the subtraction is floating point, the count integral).
#[terminating]
def drain_go (acc : F64) (delta : F64) (n : I64) : Drained :=
    if acc >= delta
    then drain_go (acc - delta) delta (I64.add n 1)
    else { leftover := acc, steps := n : Drained }

/// The clock after advancing by `dt`, and how many fixed steps to run.
#[derive Copy Clone Debug]
pub struct Step {
    clock : Clock,
    steps : I64
}

pub def clock_advance (c : Clock) (dt : F64) : Step :=
    if c.fixed_delta <= 0.0
    then { clock := c, steps := 0 : Step }
    else
        let d : Drained := drain_go (c.accumulator + dt) c.fixed_delta 0 in
        { clock := { accumulator := d.leftover, fixed_delta := c.fixed_delta : Clock },
          steps := d.steps
          : Step }

pub def clock_accumulator (c : Clock) : F64 := c.accumulator

pub def clock_fixed_delta (c : Clock) : F64 := c.fixed_delta

pub def step_clock (s : Step) : Clock := s.clock

pub def step_count (s : Step) : I64 := s.steps

#[test]
def test_stage_ordinals_are_distinct : Bool :=
    I64.beq (stage_ordinal start_s) 0
        && I64.beq (stage_ordinal cleanup_s) 11
        && I64.beq (stage_ordinal render_s) 10

#[test]
def test_stage_name : Bool :=
    String.beq (stage_name fixed_update_s) "fixed_update"

#[test]
def test_all_stages_is_pipeline_order : Bool :=
    let n : I64 := List.length all_stages in
    let third : ScheduleState := Option.get_or_default start_s (List.get 2 all_stages) in
    let last : ScheduleState := Option.get_or_default start_s (List.get 11 all_stages) in
    I64.beq n 12 && I64.beq (stage_ordinal third) 2 && I64.beq (stage_ordinal last) 11

#[test]
def test_no_conflict_between_readers : Bool :=
    let a : System := system_new "a" update_s [1] [] (system_noop) in
    let b : System := system_new "b" update_s [1] [] (system_noop) in
    Bool.not (systems_conflict a b)

#[test]
def test_conflict_on_write_write : Bool :=
    let a : System := system_new "a" update_s [] [1] (system_noop) in
    let b : System := system_new "b" update_s [] [1] (system_noop) in
    systems_conflict a b

#[test]
def test_conflict_on_read_write : Bool :=
    let a : System := system_new "a" update_s [1] [] (system_noop) in
    let b : System := system_new "b" update_s [] [1] (system_noop) in
    systems_conflict a b

#[test]
def test_two_readers_batch_together : Bool :=
    let a : System := system_new "a" update_s [1] [] (system_noop) in
    let b : System := system_new "b" update_s [1] [] (system_noop) in
    I64.beq (batch_count [a, b]) 1

#[test]
def test_two_writers_go_to_separate_batches : Bool :=
    let a : System := system_new "a" update_s [] [1] (system_noop) in
    let b : System := system_new "b" update_s [] [1] (system_noop) in
    I64.beq (batch_count [a, b]) 2

#[test]
def test_disjoint_writers_batch_together : Bool :=
    let a : System := system_new "a" update_s [] [1] (system_noop) in
    let b : System := system_new "b" update_s [] [2] (system_noop) in
    I64.beq (batch_count [a, b]) 1

#[test]
def test_clock_no_step_below_delta : Bool :=
    let s : Step := clock_advance (clock_new 0.1) 0.05 in
    I64.beq (step_count s) 0

#[test]
def test_clock_one_step : Bool :=
    let s : Step := clock_advance (clock_new 0.1) 0.1 in
    I64.beq (step_count s) 1

#[test]
def test_clock_three_steps : Bool :=
    let s : Step := clock_advance (clock_new 0.1) 0.35 in
    I64.beq (step_count s) 3

#[test]
def test_clock_keeps_the_remainder : Bool :=
    let c : Clock := clock_new 0.1 in
    let s1 : Step := clock_advance c 0.1 in
    let s2 : Step := clock_advance (step_clock s1) 0.05 in
    // After 0.15 with delta 0.1: one step fired, 0.05 remains, and 0.05 more
    // still does not fire a second.
    I64.beq (step_count s2) 0

#[test]
def test_clock_zero_delta_never_steps : Bool :=
    let s : Step := clock_advance (clock_new 0.0) 10.0 in
    I64.beq (step_count s) 0
