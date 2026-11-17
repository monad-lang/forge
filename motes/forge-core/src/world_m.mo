// forge-core WorldM: a world-threading computation over ANY base monad M.
//
// `WorldM M A = StateT World M A`. The point (PLAN.md Phase 2): a "system" is
// a COMPUTATION, not a `World -> World` function, so the same system runs
// purely in a test (`WorldM Id`), over `IO` in the app (`WorldM IO`), and over
// a fallible IO stack (`FallibleWorld`) -- without changing the system.
//
// `WorldM` is a single-constructor `type`, not a `struct`: a parameterized
// struct's constructor does not generalize its type parameters on the Rust
// host (the `StateT` note in `init/transformers.mo`), and this type is
// parameterized in both `M` and `A`.
//
// NOTE: a declaration's `[Constraint]` list must come BEFORE its `{...}` type
// binders (`[Monad M] {A : Type}`); the reverse order is a parse error.

use init::transformers {StateT}
use init::id {Id}
use lib::ecs {World}

pub type WorldM (M : Type -> Type) (A : Type) {
    mk (un : StateT World M A)
}

/// Unwrap to the underlying `StateT`.
pub def WorldM.run {M : Type -> Type} {A : Type} (m : WorldM M A) : StateT World M A :=
    match m { WorldM.mk r => r }

/// Run the computation from an initial world, giving `(world, value)` in `M`.
pub def WorldM.run_state {M : Type -> Type} {A : Type} (m : WorldM M A) (w : World) : M (Pair World A) :=
    StateT.run (WorldM.run m) w

/// Read the current world.
pub def WorldM.get [Monad M] : WorldM M World :=
    WorldM.mk (StateT.get : StateT World M World)

/// Replace the world.
pub def WorldM.put [Monad M] (w : World) : WorldM M Unit :=
    WorldM.mk (StateT.put w)

/// Modify the world.
pub def WorldM.modify [Monad M] (f : World -> World) : WorldM M Unit :=
    WorldM.mk (StateT.modify f)

/// Lift an underlying `M` computation, leaving the world untouched.
pub def WorldM.lift [Monad M] {A : Type} (m : M A) : WorldM M A :=
    WorldM.mk (StateT.lift m)

/// The `bind` step, extracted so the instance body is a single line (the
/// parser rejects a multi-line lambda inside an instance body) and so the
/// instance's `[Monad M]` binding is forwarded through the call.
def worldm_bind_go [Monad M] {A : Type} {B : Type}
    (ma : WorldM M A) (f : A -> WorldM M B) (s : World)
    : M (Pair World B) :=
    Monad.bind (StateT.run (WorldM.run ma) s)
               (fn (p : Pair World A) =>
                   match p { Pair.pair s2 a => StateT.run (WorldM.run (f a)) s2 })

pub instance [Monad M] Monad (WorldM M) {
    def pure (a : A) : WorldM M A :=
        WorldM.mk (StateT.mk (fn (s : World) => Monad.pure (Pair.pair s a)))
    def bind (ma : WorldM M A) (f : A -> WorldM M B) : WorldM M B :=
        WorldM.mk (StateT.mk (worldm_bind_go ma f))
}

/// `MonadState (WorldM M)` so `MonadState.get`/`set`/`modify` work in `do`
/// blocks over any `WorldM`.
///
/// `modify` and `get_map` are written out even though `MonadState` declares
/// them as class DEFAULTS. The self-hosted compiler splices a default body
/// into any instance that omits it (`promote_methods`), and the spliced
/// `get_map` body emits `call i64 @modify_get(...)` -- the CLASS-level method
/// name, which no concrete instance defines. `monad test` then dies at LLVM
/// lowering with `use of undefined value '@modify_get'`, AFTER the
/// type-checker has passed. Defining both methods here keeps the spliced
/// default out of the binary entirely. (Same family as PLAN.md's "instance
/// resolution is a run-time step": `monad check` is not the gate.)
pub instance [Monad M] MonadState (WorldM M) {
    def get : WorldM M World := WorldM.mk (StateT.get : StateT World M World)
    def set (s : World) : WorldM M Unit := WorldM.mk (StateT.put s)
    def modify_get (f : World -> Pair World A) : WorldM M A :=
        WorldM.mk (StateT.mk (fn (s : World) => Monad.pure (f s)))
    def modify (f : World -> World) : WorldM M Unit := WorldM.mk (StateT.modify f)
    def get_map (f : World -> A) : WorldM M A :=
        WorldM.mk (StateT.mk (fn (s : World) => Monad.pure (Pair.pair s (f s))))
}

// ── Pure alias ──────────────────────────────────────────────────────

/// A purely-evaluated world computation, for tests.
pub type PureWorld A {
    mk (run : WorldM Id A)
}

/// Run a pure computation from a world, returning `(world, value)` outright.
pub def PureWorld.run {A : Type} (m : WorldM Id A) (w : World) : Pair World A :=
    match StateT.run (WorldM.run m) w {
        Id.id p => p
    }

// ── IO and fallible aliases ─────────────────────────────────────────
//
// The same `WorldM` over the two bases an APP needs. A system written against
// `[Monad M] WorldM M` runs under any of the three runners unchanged; these
// only fix the base and name the way out.

/// A world computation that may perform IO (the app's stack).
pub type AppWorld A {
    mk (run : WorldM IO A)
}

/// Run an IO world computation from a world.
pub def AppWorld.run {A : Type} (m : WorldM IO A) (w : World) : IO (Pair World A) :=
    StateT.run (WorldM.run m) w

/// A world computation that may perform IO AND fail with a message. A
/// failure abandons the world built so far: the caller keeps the one it
/// passed in.
///
/// This is `World -> IO (Result String (Pair World A))` -- exactly what
/// `WorldM (ResultT String IO) A` unfolds to -- written out as its OWN monad
/// rather than as that transformer stack. The stack type-checks but is
/// miscompiled by the installed toolchain: `Monad.pure` through a transformer
/// over a transformer (`StateT S (ResultT E M)`, even with `M = Id`) returns a
/// value of the wrong shape, so a `Result.ok` match on it fails at run time.
/// (PLAN.md, "Gaps in monad and its motes", G1.) A monomorphic instance with
/// no dictionary parameter avoids the nested-dictionary path entirely.
/// `FallibleWorld.lift` brings any `WorldM IO` computation in, so a system
/// written once still runs here.
pub type FallibleWorld (A : Type) {
    mk (run : World -> IO (Result String (Pair World A)))
}

/// Run a fallible world computation: `ok (world, value)` or `err message`.
pub def FallibleWorld.run {A : Type} (m : FallibleWorld A) (w : World)
    : IO (Result String (Pair World A)) :=
    match m { FallibleWorld.mk r => r w }

/// Fail the computation with `msg`.
pub def FallibleWorld.fail {A : Type} (msg : String) : FallibleWorld A :=
    FallibleWorld.mk (fn (_ : World) => IO.pure (Result.err msg))

/// Succeed or fail according to an already-computed `Result`.
pub def FallibleWorld.of_result {A : Type} (r : Result String A) : FallibleWorld A :=
    match r {
        Result.ok a => FallibleWorld.mk (fn (w : World) => IO.pure (Result.ok (Pair.pair w a))),
        Result.err e => FallibleWorld.mk (fn (_ : World) => IO.pure (Result.err e))
    }

def fallible_ok {A : Type} (p : Pair World A) : IO (Result String (Pair World A)) :=
    IO.pure (Result.ok p)

def fallible_lift_go {A : Type} (m : WorldM IO A) (w : World) : IO (Result String (Pair World A)) :=
    Monad.bind (AppWorld.run m w) fallible_ok

/// Run an infallible IO world computation inside the fallible stack.
pub def FallibleWorld.lift {A : Type} (m : WorldM IO A) : FallibleWorld A :=
    FallibleWorld.mk (fallible_lift_go m)

/// Read the current world.
pub def FallibleWorld.get : FallibleWorld World :=
    FallibleWorld.mk (fn (w : World) => IO.pure (Result.ok (Pair.pair w w)))

/// Modify the world.
pub def FallibleWorld.modify (f : World -> World) : FallibleWorld Unit :=
    FallibleWorld.mk (fn (w : World) => IO.pure (Result.ok (Pair.pair (f w) unit)))

def fallible_step {A : Type} {B : Type} (f : A -> FallibleWorld B) (r : Result String (Pair World A))
    : IO (Result String (Pair World B)) :=
    match r {
        Result.err e => IO.pure (Result.err e),
        Result.ok p => match p { Pair.pair w a => FallibleWorld.run (f a) w }
    }

def fallible_bind_go {A : Type} {B : Type} (ma : FallibleWorld A) (f : A -> FallibleWorld B) (w : World)
    : IO (Result String (Pair World B)) :=
    Monad.bind (FallibleWorld.run ma w) (fallible_step f)

pub instance Monad FallibleWorld {
    def pure (a : A) : FallibleWorld A :=
        FallibleWorld.mk (fn (w : World) => IO.pure (Result.ok (Pair.pair w a)))
    def bind (ma : FallibleWorld A) (f : A -> FallibleWorld B) : FallibleWorld B :=
        FallibleWorld.mk (fallible_bind_go ma f)
}
