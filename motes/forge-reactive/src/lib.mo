// forge-reactive: `Signal`/`Derived` over `Ref`, and `EventStream` with a
// per-frame drain budget. Phase 6, see ../../../PLAN.md.
//
// Every operation is `IO` (`std::ref`'s natives), and both `Signal A` and
// `EventStream A` are parameterized -- so they are not `Copy` and travel as
// `Shared (Signal A)` / `Shared (EventStream A)`. See `reactive.mo`'s header.

pub use lib::reactive {
    Signal, signal_new, signal_get, signal_version, signal_set, signal_update,
    Derived, Derived2, Derived3,
    derived_get, derived2_get, derived3_get,
    signal_map, derived_map, signal_zip2, signal_zip3, signal_fold,
    Memo, signal_memo, memo_get, memo_computes, memo_derived
}
pub use lib::event {
    EventStream, event_stream_new,
    event_send, event_pending, event_drain, event_drain_all, event_clear,
    event_max_per_frame
}
