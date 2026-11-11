// forge-reactive integration tests, over the PUBLIC surface (`lib::{...}`).
//
// The in-file unit tests cover each module; these drive the two together the
// way a frame would: events arrive, get drained under a budget, and a signal
// (with a derived view) tracks accumulated state.

use lib::{
    Signal, signal_new, signal_get, signal_set, signal_update,
    Derived, derived_get, derived_map, signal_map, signal_zip2,
    event_stream_new, event_send, event_pending, event_drain, event_drain_all
}

/// Sum the drained events into a signal, then read a derived doubled view.
#[test]
def test_drain_into_a_signal : IO Bool := do {
    let events <- event_stream_new 10u64;
    let total <- signal_new 0;
    event_send events 1;
    event_send events 2;
    event_send events 3;
    let batch <- event_drain events;
    let _ <- signal_update total (fn (s : I64) => I64.add s (sum_of batch));
    let v <- signal_get total;
    return (I64.beq v 6)
}

def sum_of (xs : List I64) : I64 :=
    sum_go xs 0

#[terminating]
def sum_go (xs : List I64) (acc : I64) : I64 :=
    match xs {
        List.empty => acc,
        List.cons h t => sum_go t (I64.add acc h)
    }

/// A budgeted frame loop: three events, budget two, so the count drains over
/// two frames.
#[test]
def test_budgeted_drain_takes_two_frames : IO Bool := do {
    let events <- event_stream_new 2u64;
    let frames <- signal_new 0;
    event_send events 1;
    event_send events 2;
    event_send events 3;
    let first <- event_drain events;
    let _ <- signal_update frames (fn (n : I64) => I64.add n 1);
    let second <- event_drain events;
    let _ <- signal_update frames (fn (n : I64) => I64.add n 1);
    let f <- signal_get frames;
    let left <- event_pending events;
    let n1 : I64 := List.length first;
    let n2 : I64 := List.length second;
    return (I64.beq f 2 && I64.beq n1 2 && I64.beq n2 1 && I64.beq left 0)
}

/// A signal drives a derived view, and a second derived consumes the first.
#[test]
def test_derived_chain_over_a_signal : IO Bool := do {
    let health <- signal_new 100;
    let half := signal_map (fn (h : I64) => I64.div h 2) health;
    let label : Shared (Derived I64) := derived_map (fn (x : I64) => I64.add x 1) half;
    let before <- derived_get label;
    let _ <- signal_update health (fn (h : I64) => I64.sub h 20);
    let after <- derived_get label;
    return (I64.beq before 51 && I64.beq after 41)
}

/// Two signals zipped, where only one changes.
#[test]
def test_zip2_reacts_to_one_side : IO Bool := do {
    let a <- signal_new 1;
    let b <- signal_new 100;
    let d := signal_zip2 (fn (x : I64) (y : I64) => I64.add x y) a b;
    let v1 <- derived_get d;
    signal_set b 200;
    let v2 <- derived_get d;
    return (I64.beq v1 101 && I64.beq v2 201)
}

/// A full frame: send a burst, drain everything, apply, then drain again to
/// find the queue empty.
#[test]
def test_frame_drain_then_next_frame_is_quiet : IO Bool := do {
    let events <- event_stream_new 100u64;
    let applied <- signal_new 0;
    event_send events 5;
    event_send events 5;
    let batch <- event_drain_all events;
    let _ <- signal_update applied (fn (s : I64) => I64.add s (sum_of batch));
    let next <- event_drain_all events;
    let total <- signal_get applied;
    let n : I64 := List.length next;
    return (I64.beq total 10 && I64.beq n 0)
}

/// `signal_set` to a brand-new value, read through a derived identity view.
#[test]
def test_derived_sees_a_set_after_the_view_is_made : IO Bool := do {
    let s <- signal_new 1;
    let d := signal_map (fn (x : I64) => x) s;
    signal_set s 42;
    let v <- derived_get d;
    return (I64.beq v 42)
}
