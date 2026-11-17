// WorldM over the pure `Id` base. Instance resolution is a RUN-TIME step, so
// these tests EXECUTE the `Monad`/`MonadState` instances rather than merely
// type-checking them (see PLAN.md's "the real gate is monad test").
//
// Every computation is bound to a top-level `def` (or a typed `let`) before
// it is run. That is not cosmetic: an INLINE application of a
// `[Constraint]`-bearing def used as an ARGUMENT -- e.g.
// `WorldM.run_state (WorldM.put w) s` -- compiles to a broken partial shim
// and the test driver dies with `driver exited -1` (no diagnostic; the
// `check` pass is clean). Hoisting the computation first is the workaround,
// and it is the shape the toolchain's own `init/transformers_tests.mo`
// uses for `StateT.put`/`get`/`modify`.

use lib::ecs {World, Spawned, spawn, empty_world, world_archetype_count}
use lib::world_m {
    WorldM, WorldM.run_state, WorldM.put, WorldM.modify, WorldM.get, WorldM.lift,
    PureWorld.run, AppWorld.run, FallibleWorld, FallibleWorld.run, FallibleWorld.fail,
    FallibleWorld.lift, FallibleWorld.modify, FallibleWorld.get, FallibleWorld.of_result
}
use init::id {Id}

def spawn_pos (w : World) : World :=
    let s : Spawned := spawn w [Pair.pair "pos" (Any.any 1u64)] in
    s.world

/// `Monad (WorldM Id)` sequenced: read the world, project its archetype count.
def read_count : WorldM Id I64 :=
    Monad.bind WorldM.get (fn (w : World) => Monad.pure (world_archetype_count w))

/// Reset the world to empty.
def reset_world : WorldM Id Unit := WorldM.put empty_world

/// Spawn one entity into the world.
def spawn_one : WorldM Id Unit := WorldM.modify spawn_pos

/// `MonadState.get_map` (a class DEFAULT the instance re-declares, see
/// `world_m.mo`).
def count_map : WorldM Id I64 :=
    MonadState.get_map (fn (w : World) => world_archetype_count w)

/// `Monad.pure` in the `WorldM Id` stack. (`PureWorld.run` consumes a
/// `WorldM Id A`, not a `PureWorld A`.)
def pure_42 : WorldM Id I64 := Monad.pure 42

#[test]
def test_bind_reads_the_world : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    match WorldM.run_state read_count spawned.world {
        Id.id p => match p { Pair.pair _ n => I64.beq n 1 }
    }

#[test]
def test_run_state_preserves_the_world : Bool :=
    match WorldM.run_state read_count empty_world {
        Id.id p => match p { Pair.pair w n => I64.beq (world_archetype_count w) n }
    }

#[test]
def test_set_replaces_the_world : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    match WorldM.run_state reset_world spawned.world {
        Id.id p => match p { Pair.pair w _ => I64.beq (world_archetype_count w) 0 }
    }

#[test]
def test_modify_threads_a_new_world : Bool :=
    match WorldM.run_state spawn_one empty_world {
        Id.id p => match p { Pair.pair w _ => I64.beq (world_archetype_count w) 1 }
    }

#[test]
def test_monadstate_get_map : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    match WorldM.run_state count_map spawned.world {
        Id.id p => match p { Pair.pair _ n => I64.beq n 1 }
    }

#[test]
def test_pure_world_alias_run : Bool :=
    match PureWorld.run pure_42 empty_world {
        Pair.pair _ n => I64.beq n 42
    }

// ── The IO and fallible stacks ──────────────────────────────────────
//
// The same shapes as above over `IO` and over `ResultT String IO`. Each is
// EXECUTED: `Monad (WorldM IO)` resolves through `Monad (StateT World IO)` to
// `Monad IO`, and the fallible one through `Monad (ResultT String IO)` too --
// one more level than the pure stack, and resolution only happens at run time.

def io_spawn : WorldM IO Unit := WorldM.modify spawn_pos

def io_count : WorldM IO I64 :=
    Monad.bind WorldM.get (fn (w : World) => Monad.pure (world_archetype_count w))

def io_spawn_then_count : WorldM IO I64 :=
    Monad.bind io_spawn (fn (_ : Unit) => io_count)

def io_seven : IO I64 := IO.pure 7

def io_lifted : WorldM IO I64 := WorldM.lift io_seven

#[test]
def test_app_world_runs_over_io : IO Bool := do {
    let p <- AppWorld.run io_spawn_then_count empty_world;
    match p {
        Pair.pair w n => return (I64.beq n 1 && I64.beq (world_archetype_count w) 1)
    }
}

#[test]
def test_app_world_lifts_an_io_action : IO Bool := do {
    let p <- AppWorld.run io_lifted empty_world;
    match p {
        Pair.pair w n => return (I64.beq n 7 && I64.beq (world_archetype_count w) 0)
    }
}

// `FallibleWorld` is its own monad (see world_m.mo for why it is not the
// `WorldM (ResultT String IO)` stack), so its instance is executed here too.

def fallible_spawn : FallibleWorld Unit := FallibleWorld.modify spawn_pos

def fallible_boom : FallibleWorld Unit := FallibleWorld.fail "boom"

def fallible_spawn_then_boom : FallibleWorld Unit :=
    Monad.bind fallible_spawn (fn (_ : Unit) => fallible_boom)

def fallible_count : FallibleWorld I64 :=
    Monad.bind FallibleWorld.get (fn (w : World) => Monad.pure (world_archetype_count w))

def fallible_spawn_then_count : FallibleWorld I64 :=
    Monad.bind fallible_spawn (fn (_ : Unit) => fallible_count)

/// A `WorldM IO` system, reused unchanged inside the fallible stack.
def fallible_lifted : FallibleWorld I64 := FallibleWorld.lift io_spawn_then_count

def a_parse_error : Result String I64 := Result.err "bad input"

def fallible_from_result : FallibleWorld I64 := FallibleWorld.of_result a_parse_error

#[test]
def test_fallible_world_ok_path : IO Bool := do {
    let r <- FallibleWorld.run fallible_spawn_then_count empty_world;
    match r {
        Result.ok p => match p { Pair.pair w n => return (I64.beq n 1 && I64.beq (world_archetype_count w) 1) },
        Result.err _ => return false
    }
}

#[test]
def test_fallible_world_failure_carries_the_message : IO Bool := do {
    let r <- FallibleWorld.run fallible_spawn_then_boom empty_world;
    match r {
        Result.ok _ => return false,
        Result.err e => return (String.beq e "boom")
    }
}

#[test]
def test_fallible_world_lifts_an_io_system : IO Bool := do {
    let r <- FallibleWorld.run fallible_lifted empty_world;
    match r {
        Result.ok p => match p { Pair.pair _ n => return (I64.beq n 1) },
        Result.err _ => return false
    }
}

#[test]
def test_fallible_world_of_result_err : IO Bool := do {
    let r <- FallibleWorld.run fallible_from_result empty_world;
    match r {
        Result.ok _ => return false,
        Result.err e => return (String.beq e "bad input")
    }
}
