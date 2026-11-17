// forge-schedule: ScheduleState stages, System registration, conflict-based
// batching, the Schedule builder, fixed timestep and the Time resource.
// Phase 4, see ../../../PLAN.md.
//
// Systems carry a `WorldM Id Unit` computation, so the whole schedule is PURE
// (`World -> World`) and runs inside `monad test`. The app's IO loop and
// fiber-parallel batch execution are Phase 7; `stage_batches` is the metadata
// it will consume.

pub use lib::system {
    ScheduleState,
    start_s, pre_init_s, init_s, first_s, pre_update_s, state_transition_s,
    fixed_update_s, update_s, post_update_s, last_s, render_s, cleanup_s,
    stage_ordinal, stage_name, all_stages, stage_count,
    System, system_new, system_pure, system_name, system_stage,
    system_stage_ordinal, system_reads, system_writes, system_run,
    system_in_stage, system_noop,
    ids_overlap, systems_conflict, batches, batch_count,
    Clock, clock_new, clock_advance, clock_accumulator, clock_fixed_delta,
    step_clock, step_count, Drained, Step
}
pub use lib::schedule {
    Schedule, empty_schedule, add_system, add_system_to, schedule_systems,
    schedule_len, systems_in_stage, stage_system_count, stage_batches,
    run_systems, run_stage, run_schedule, run_schedule_pure, run_fixed_steps,
    run_schedule_timed, run_frame,
    Time, time_new, time_advance, time_elapsed, time_delta, time_fixed_steps,
    time_accumulator, time_fixed_delta,
    time_name, default_fixed_delta, world_time_opt, world_time, world_set_time,
    world_advance_time
}
