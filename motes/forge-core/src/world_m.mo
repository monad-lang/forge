// forge-core WorldM: a world-threading computation over ANY base monad M.
//
// `WorldM M A = StateT World M A`. The point (PLAN.md Phase 2): a "system" is
// a COMPUTATION, not a `World -> World` function, so the same system runs
// purely in a test (`WorldM Id`), over `IO` in the app (`WorldM IO`), and over
// `ResultT String IO` when fallible -- without changing the system.
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
