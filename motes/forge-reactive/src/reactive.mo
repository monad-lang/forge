// forge-reactive: `Signal` (a shared, versioned cell) and `Derived` (a
// recompute-on-read view over signals). Phase 6, see ../../../PLAN.md.
//
// Every operation is `IO` -- `std::ref`'s `Ref.new`/`get`/`set`/`update` are IO
// natives, and `Ref.update` is the only atomic read-modify-write -- so a
// `Signal` is `IO (Shared (Signal A))` and reading one is `IO A`.
//
// ## Why `Shared`
//
// `Signal A` is parameterized, and a parameterized type can neither derive nor
// hand-write a `Copy` instance (`Copy` is a single-parameter class keyed on one
// carrier). A bare `Signal A` binder is therefore affine: reading a signal
// twice would be a "used 2 times but is affine" error. `Shared A` is `Copy`
// UNCONDITIONALLY, so signals travel as `Shared (Signal A)`. Inside an
// accessor, the handle is destructured exactly once and its `Ref` fields are
// read (a `Ref A` IS `Copy`).
//
// ## Derived values
//
// A true subscription graph needs mutable listener lists and callbacks at set
// time -- engine-scale machinery. `Derived A` is the cheap, honest alternative:
// it holds a thunk that READS its sources when the value is demanded, so it is
// always current by construction and never needs invalidation. It recomputes
// on every read; a memoizing cache (a `Ref` of the last value + the version it
// was computed at) is the obvious next step and is left as a TODO.

use std::derive {derive_copy, derive_clone, derive_debug}
use std::ref {Ref, Ref.new, Ref.get, Ref.set, Ref.update}
use std::list {}

// ── Signal ──────────────────────────────────────────────────────────

/// A value cell plus a version counter, bumped on every write so a reader can
/// tell "changed since" without comparing payloads.
pub type Signal (A : Type) {
    mk (value : Ref A, version : Ref U64)
}

/// A fresh signal holding `a`, at version 0.
pub def signal_new (a : A) : IO (Shared (Signal A)) := do {
    let v <- Ref.new a;
    let n <- Ref.new 0u64;
    return (Shared.of (Signal.mk v n))
}

/// The current value.
pub def signal_get (sh : Shared (Signal A)) : IO A :=
    match Shared.get sh {
        Signal.mk v _ => Ref.get v
    }

/// The current version (bumped once per `signal_set`).
pub def signal_version (sh : Shared (Signal A)) : IO U64 :=
    match Shared.get sh {
        Signal.mk _ n => Ref.get n
    }

/// Store a new value and bump the version. The value store and the version
/// bump are two `Ref` writes; a reader between them sees the new value at the
/// old version, which is why `signal_set` should be called from one fiber.
pub def signal_set (sh : Shared (Signal A)) (a : A) : IO Unit :=
    match Shared.get sh {
        Signal.mk v n => do {
            Ref.set v a;
            let _ <- Ref.update n (fn (x : U64) => U64.add x 1u64);
            return unit
        }
    }

/// Atomic read-modify-write of the value, bumping the version.
pub def signal_update (sh : Shared (Signal A)) (f : A -> A) : IO A :=
    match Shared.get sh {
        Signal.mk v n => do {
            let new_v <- Ref.update v f;
            let _ <- Ref.update n (fn (x : U64) => U64.add x 1u64);
            return new_v
        }
    }

// ── Derived ─────────────────────────────────────────────────────────

/// A view that recomputes from its sources on every read.
pub type Derived (A : Type) {
    mk (run : Unit -> IO A)
}

pub type Derived2 (A : Type) {
    mk2 (run2 : Unit -> IO A)
}

pub type Derived3 (A : Type) {
    mk3 (run3 : Unit -> IO A)
}

/// Demand the value (recomputing it).
pub def derived_get (d : Shared (Derived A)) : IO A :=
    match Shared.get d { Derived.mk f => f unit }

pub def derived2_get (d : Shared (Derived2 A)) : IO A :=
    match Shared.get d { Derived2.mk2 f => f unit }

pub def derived3_get (d : Shared (Derived3 A)) : IO A :=
    match Shared.get d { Derived3.mk3 f => f unit }

/// `map` over a signal.
pub def signal_map (f : A -> B) (sh : Shared (Signal A)) : Shared (Derived B) :=
    Shared.of (Derived.mk (fn (_ : Unit) => do {
        let v <- signal_get sh;
        return (f v)
    }))

/// `map` over a derived value.
pub def derived_map (f : A -> B) (d : Shared (Derived A)) : Shared (Derived B) :=
    Shared.of (Derived.mk (fn (_ : Unit) => do {
        let v <- derived_get d;
        return (f v)
    }))

/// Combine two signals with a pure function.
pub def signal_zip2
    (f : A -> B -> C)
    (sa : Shared (Signal A))
    (sb : Shared (Signal B))
    : Shared (Derived C) :=
    Shared.of (Derived.mk (fn (_ : Unit) => do {
        let a <- signal_get sa;
        let b <- signal_get sb;
        return (f a b)
    }))

/// Combine three signals with a pure function.
pub def signal_zip3
    (f : A -> B -> C -> D)
    (sa : Shared (Signal A))
    (sb : Shared (Signal B))
    (sc : Shared (Signal C))
    : Shared (Derived D) :=
    Shared.of (Derived.mk (fn (_ : Unit) => do {
        let a <- signal_get sa;
        let b <- signal_get sb;
        let c <- signal_get sc;
        return (f a b c)
    }))

/// Fold a signal: recompute `f state (current value)` from a fixed initial
/// state on every read. (A *running* fold -- one that remembers what it has
/// seen -- needs a `Ref` of the accumulator; `signal_fold` below is the pure
/// "reduce the current value" form, which is what a derived read wants.)
pub def signal_fold (f : B -> A -> B) (init : B) (sh : Shared (Signal A)) : Shared (Derived B) :=
    Shared.of (Derived.mk (fn (_ : Unit) => do {
        let v <- signal_get sh;
        return (f init v)
    }))

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_signal_new_holds_its_value : IO Bool := do {
    let s <- signal_new 7;
    let v <- signal_get s;
    return (I64.beq v 7)
}

#[test]
def test_signal_set_changes_the_value : IO Bool := do {
    let s <- signal_new 1;
    signal_set s 9;
    let v <- signal_get s;
    return (I64.beq v 9)
}

#[test]
def test_signal_version_starts_at_zero : IO Bool := do {
    let s <- signal_new 1;
    let n <- signal_version s;
    return (U64.beq n 0u64)
}

#[test]
def test_signal_version_bumps_per_set : IO Bool := do {
    let s <- signal_new 1;
    signal_set s 2;
    signal_set s 3;
    let n <- signal_version s;
    return (U64.beq n 2u64)
}

#[test]
def test_signal_update_read_modify_write : IO Bool := do {
    let s <- signal_new 10;
    let v <- signal_update s (fn (x : I64) => I64.add x 5);
    let stored <- signal_get s;
    return (I64.beq v 15 && I64.beq stored 15)
}

#[test]
def test_signal_update_bumps_the_version : IO Bool := do {
    let s <- signal_new 1;
    let _ <- signal_update s (fn (x : I64) => I64.add x 1);
    let n <- signal_version s;
    return (U64.beq n 1u64)
}

#[test]
def test_two_signals_are_independent : IO Bool := do {
    let a <- signal_new 1;
    let b <- signal_new 2;
    signal_set a 10;
    let va <- signal_get a;
    let vb <- signal_get b;
    return (I64.beq va 10 && I64.beq vb 2)
}

#[test]
def test_signal_map_recomputes : IO Bool := do {
    let s <- signal_new 3;
    let d := signal_map (fn (x : I64) => I64.add x 1) s;
    let a <- derived_get d;
    signal_set s 10;
    let b <- derived_get d;
    return (I64.beq a 4 && I64.beq b 11)
}

#[test]
def test_signal_map_sees_the_latest_value : IO Bool := do {
    let s <- signal_new 1;
    let d := signal_map (fn (x : I64) => I64.mul x 2) s;
    signal_set s 5;
    signal_set s 6;
    let v <- derived_get d;
    return (I64.beq v 12)
}

#[test]
def test_derived_map_chains : IO Bool := do {
    let s <- signal_new 2;
    let a := signal_map (fn (x : I64) => I64.add x 1) s;
    let b := derived_map (fn (x : I64) => I64.mul x 10) a;
    let v <- derived_get b;
    signal_set s 4;
    let v2 <- derived_get b;
    return (I64.beq v 30 && I64.beq v2 50)
}

#[test]
def test_signal_zip2 : IO Bool := do {
    let a <- signal_new 3;
    let b <- signal_new 4;
    let d := signal_zip2 (fn (x : I64) (y : I64) => I64.add x y) a b;
    let v <- derived_get d;
    signal_set a 10;
    let v2 <- derived_get d;
    return (I64.beq v 7 && I64.beq v2 14)
}

#[test]
def test_signal_zip3 : IO Bool := do {
    let a <- signal_new 1;
    let b <- signal_new 2;
    let c <- signal_new 3;
    let d := signal_zip3 (fn (x : I64) (y : I64) (z : I64) => I64.add x (I64.add y z)) a b c;
    let v <- derived_get d;
    return (I64.beq v 6)
}

#[test]
def test_signal_fold : IO Bool := do {
    let s <- signal_new 5;
    // 10 - current, with the state fixed at 10.
    let d := signal_fold (fn (acc : I64) (x : I64) => I64.sub acc x) 10 s;
    let v <- derived_get d;
    signal_set s 3;
    let v2 <- derived_get d;
    return (I64.beq v 5 && I64.beq v2 7)
}

#[test]
def test_signal_values_lists : IO Bool := do {
    let a <- signal_new "x";
    let b <- signal_new "y";
    signal_set b "z";
    let va <- signal_get a;
    let vb <- signal_get b;
    return (String.beq va "x" && String.beq vb "z")
}
