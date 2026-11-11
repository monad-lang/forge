// forge-reactive: `EventStream A`, a shared queue with a per-frame drain
// budget. Phase 6, see ../../../PLAN.md.
//
// Like `Signal`, an `EventStream A` is parameterized (so not `Copy`) and travels
// as `Shared (EventStream A)`; the buffer is a `Ref (List A)`, and every
// operation is `IO`.
//
// `event_drain` is the frame-budgeted consumer: it takes up to `max_per_frame`
// events from the FRONT (FIFO) and leaves the rest, so a burst never costs a
// single unbounded frame. Its read-and-truncate is a `Ref.get` then a
// `Ref.set`, NOT one atomic `Ref.update` -- `Ref.update` returns the NEW value,
// so it cannot hand back the prefix it removed. That is sound for the intended
// shape (one writer, one reader per frame); concurrent drainers are not
// supported.

use std::ref {Ref, Ref.new, Ref.get, Ref.set, Ref.update}
use std::derive {derive_copy, derive_clone, derive_debug}

/// A FIFO event queue with a per-frame drain budget.
pub type EventStream (A : Type) {
    mk (buffer : Ref (List A), max_per_frame : U64)
}

pub def event_stream_new (max_per_frame : U64) : IO (Shared (EventStream A)) := do {
    let b <- Ref.new ([] : List A);
    return (Shared.of (EventStream.mk b max_per_frame))
}

/// Split off the first `n` elements in ONE pass: `(taken, rest)`. Returning a
/// pair rather than calling a take and a drop is what keeps the caller's `xs`
/// used exactly once (the affine rule) AND lets the pair be destructured once.
#[terminating]
def split_at (xs : List A) (n : I64) : Pair (List A) (List A) :=
    if I64.lt 0 n
    then match xs {
        List.empty => Pair.pair [] [],
        List.cons h t =>
            match split_at t (I64.sub n 1) {
                Pair.pair taken rest => Pair.pair (List.cons h taken) rest
            }
    }
    else Pair.pair [] xs

/// Enqueue one event (atomically appended).
pub def event_send (sh : Shared (EventStream A)) (a : A) : IO Unit :=
    match Shared.get sh {
        EventStream.mk b _ => do {
            let _ <- Ref.update b (fn (xs : List A) => List.append xs [a]);
            return unit
        }
    }

/// How many events are queued.
pub def event_pending (sh : Shared (EventStream A)) : IO I64 :=
    match Shared.get sh {
        EventStream.mk b _ => do {
            let xs <- Ref.get b;
            return (List.length xs)
        }
    }

/// Take up to `max_per_frame` events from the front, leaving the rest queued.
pub def event_drain (sh : Shared (EventStream A)) : IO (List A) :=
    match Shared.get sh {
        EventStream.mk b budget => do {
            let xs <- Ref.get b;
            let n : I64 := U64.to_i64 budget;
            match split_at xs n {
                Pair.pair taken rest => do {
                    Ref.set b rest;
                    return taken
                }
            }
        }
    }

/// Take EVERY queued event (ignoring the budget).
pub def event_drain_all (sh : Shared (EventStream A)) : IO (List A) :=
    match Shared.get sh {
        EventStream.mk b _ => do {
            let xs <- Ref.get b;
            Ref.set b ([] : List A);
            return xs
        }
    }

/// Throw every queued event away.
pub def event_clear (sh : Shared (EventStream A)) : IO Unit :=
    match Shared.get sh {
        EventStream.mk b _ => do {
            Ref.set b ([] : List A);
            return unit
        }
    }

/// The current per-frame budget.
pub def event_max_per_frame (sh : Shared (EventStream A)) : IO U64 :=
    match Shared.get sh {
        EventStream.mk _ budget => Monad.pure budget
    }

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_new_stream_is_empty : IO Bool := do {
    let s <- event_stream_new 10u64;
    let n <- event_pending s;
    return (I64.beq n 0)
}

#[test]
def test_send_then_pending : IO Bool := do {
    let s <- event_stream_new 10u64;
    event_send s 1;
    let n <- event_pending s;
    return (I64.beq n 1)
}

#[test]
def test_pending_counts_three : IO Bool := do {
    let s <- event_stream_new 10u64;
    event_send s 1;
    event_send s 2;
    event_send s 3;
    let n <- event_pending s;
    return (I64.beq n 3)
}

#[test]
def test_drain_respects_the_budget : IO Bool := do {
    let s <- event_stream_new 2u64;
    event_send s 1;
    event_send s 2;
    event_send s 3;
    let taken <- event_drain s;
    let left <- event_pending s;
    return (I64.beq (List.length taken) 2 && I64.beq left 1)
}

#[test]
def test_drain_twice_empties_the_queue : IO Bool := do {
    let s <- event_stream_new 2u64;
    event_send s 1;
    event_send s 2;
    event_send s 3;
    let _ <- event_drain s;
    let second <- event_drain s;
    let left <- event_pending s;
    return (I64.beq (List.length second) 1 && I64.beq left 0)
}

#[test]
def test_drain_empty_returns_nothing : IO Bool := do {
    let s <- event_stream_new 10u64;
    let taken <- event_drain s;
    return (I64.beq (List.length taken) 0)
}

#[test]
def test_zero_budget_drains_nothing : IO Bool := do {
    let s <- event_stream_new 0u64;
    event_send s 1;
    let taken <- event_drain s;
    let left <- event_pending s;
    return (I64.beq (List.length taken) 0 && I64.beq left 1)
}

#[test]
def test_drain_all_ignores_the_budget : IO Bool := do {
    let s <- event_stream_new 1u64;
    event_send s 1;
    event_send s 2;
    event_send s 3;
    let taken <- event_drain_all s;
    let left <- event_pending s;
    return (I64.beq (List.length taken) 3 && I64.beq left 0)
}

#[test]
def test_clear_drops_everything : IO Bool := do {
    let s <- event_stream_new 10u64;
    event_send s 1;
    event_send s 2;
    event_clear s;
    let left <- event_pending s;
    return (I64.beq left 0)
}

#[test]
def test_max_per_frame_reads_back : IO Bool := do {
    let s <- event_stream_new 7u64;
    let b <- event_max_per_frame s;
    return (U64.beq b 7u64)
}

/// FIFO order, read via the list's own helpers rather than a nested pattern.
#[test]
def test_drain_is_fifo : IO Bool := do {
    let s <- event_stream_new 10u64;
    event_send s 1;
    event_send s 2;
    event_send s 3;
    let taken <- event_drain s;
    let sh : Shared (List I64) := Shared.of taken;
    let n : I64 := List.length (Shared.get sh);
    let first : Option I64 := List.first (Shared.get sh);
    let last : Option I64 := List.last (Shared.get sh);
    match first {
        Option.none => return (false),
        Option.some a =>
            match last {
                Option.none => return (false),
                Option.some c => return (I64.beq n 3 && I64.beq a 1 && I64.beq c 3)
            }
    }
}
