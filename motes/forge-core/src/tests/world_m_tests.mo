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
    WorldM, WorldM.run_state, WorldM.put, WorldM.modify, WorldM.get, PureWorld.run
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
