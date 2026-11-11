# Forge — Game Engine Implementation Plan

## Summary

Implement the Forge game engine as a workspace of Monad motes: a flexible
core built on **monad transformers** (`StateT` over any base monad) and
**efficient data structures** (`Array`, `HashMap`, `Ref`), with MLIR/GPU and
WebGL backends landing later behind a stable render interface.

This revision supersedes the original plan. The original was written against
a much earlier `monad`: three of its "gaps" were toolchain bugs that have
since been fixed, and one of its core conventions (threading a plain struct
by value) is now a **compile error**. See "Toolchain baseline" below — every
claim there was verified against the installed toolchain with `monad check`
and `monad eval`, not inferred.

### Workspace setup

A bare `mote.toml` with just `[mote]` (name/version/edition) is enough for a
leaf mote. Cross-mote dependencies use explicit path entries:

```toml
[dependencies.forge_core]        # the KEY is what `use` spells
path = "../forge-core"           # the directory may keep its hyphen
```

then `use forge_core::ecs {World}`. A hyphen in the key is a parse error at
the `use`, so key it with `_`.

No `init`/`std`/`runtime` deps are needed: the installed toolchain supplies
those (a nightly unpacks `init`/`std`/`llvm`/`runtime` sources beside the
compiler; `MONAD_ROOT` points at another root).

### Source file preamble

No `open init` is needed — it resolves ambiently from the installed
toolchain. Source files start directly with declarations. Ambient are
`prelude` (which carries the `List`/`Pair`/`Option`/`Result` *types* and
`List.append`/`List.map`/`List.first`), `init::list`/`init::string` (and the
rest of the `init` hub), plus `std.path`/`std.io`/`std.process`. Everything
else needs an explicit `use`: `HashMap`/`BTreeMap`/`Map` from `std::map`,
`List.any`/`List.all`/`List.filter`/`List.sort_by`/`List.contains_by` from
`std::list`. (`List.length`/`List.get` are the odd ones out — they are in the
ambient `init::list`, so importing them from `std::list` errors.)

## Toolchain baseline (verified 2026-11)

This is the ground truth the rest of the plan is built on. Each row was
checked with `monad check` against a probe buffer, and the affine rule was
confirmed with `monad eval`.

### Affine-by-default is enforced — this drives the whole design

An **unannotated binder may be used at most once** unless `Copy A` resolves.
This runs on every `check`/`compile`/`run`/`test`/`eval` path. There is no
off switch; a mote may opt into warnings while migrating with:

```toml
[affine]
mode = "warn"
```

The checked-in `ecs.mo` originally failed with ~35 of these — the shape of the
diagnostic is:

```
error: `storage` : ComponentStorage is used 4 times but is affine; share it
       with `Shared`, give its type a Copy instance, or copy it with `Clone.clone`
```

`motes/forge-core/src/ecs.mo` is now rewritten and `monad check`s clean under
the rule (see Phase 1). The old plan's *"`World` is a plain struct threaded by convention ... not
linearly enforced"* is **false**, and the read-several-fields style the old
`ecs.mo` was written in is now an error.

**Three ways to satisfy the rule, in order of preference:**

1. **`#[derive Copy Clone]`** on a monomorphic struct whose fields are all
   scalars (`U64`/`I64`/`F64`/`Bool`/`String`, or a nested type that is itself
   `Copy`). This is the default for POD: `Entity`, `ComponentId`, `Loc`, all
   math types, all `RenderCommand`s. On a struct that *also* holds a
   `List`/`HashMap` the derive alone is not enough — it satisfies the affine
   gate but its generated `Copy.copy` cannot elaborate (next paragraph).
2. **A hand-written `instance Copy T`** for a *persistent* type whose fields
   are immutable and shared by pointer (`List`, `HashMap`). Duplicating the
   handle shares, never mutates — the same reasoning `std` uses for
   `Copy Nat` and `Copy (Array A)`. `World` and `ComponentStorage` use this.
   It requires the type to be monomorphic (a generic type cannot derive or
   easily write `Copy` — `MetaDecl.d_instance` carries no constraints).
3. **`Shared.of` / `Shared.get`** for a borrowed read, or a **single
   destructuring `match`** to read a non-Copy value's fields once:

   ```monad
   // rejected: `s` used 3 times
   def bad (s : Storage) : Storage :=
       { a := s.a, b := s.b, c := s.c }

   // accepted: destructure once
   def ok (s : Storage) : Storage :=
       match s { { a, b, c } => { a := a, b := b, c := c } }
   ```

`String` is `Copy` (an immutable pointer); `List`, `HashMap`, `ByteBuf` are
not. **Generic types cannot derive `Copy`** — write the generic record as a
`type` with a positional constructor and hand-write the instance, or keep it
non-`Copy` and use `Shared`/single-match.

**`#[derive Copy ...]` is a NO-OP unless the file contains `use std::derive {}`.**
Without that import a struct written with a `Copy` derive is still affine, and
the diagnostic ("`x` is used N times but is affine") points at a type that
*looks* `Copy` — a silent, expensive trap. Every file that derives `Copy` must
import `std::derive`. With the import present, `#[derive Copy]` works for a
monomorphic struct even when its fields are `List`/`HashMap`/`String`.

But a *derived* `Copy` on such a type is only half a `Copy`. The generated
`Copy.copy` body duplicates each field, so it needs `Copy (List A)` /
`Copy (HashMap K V)` — instances `init/src/copy.mo` deliberately does not
provide. The affine gate is satisfied (reads of `x.ids`/`x.k` pass), yet an
ELABORATION that actually *calls* `Copy.copy` on the value fails with
`type mismatch: expected A, found T`. That is what breaks `StateT.get`
(declared `[Monad M, Copy S]`) on a `World`-shaped state. A persistent type
therefore wants a **hand-written identity `instance Copy T`**
(`def copy (x : T) : Pair T T := Pair.pair x x`, no per-field duplication): it
satisfies the gate *and* elaboration, and it is honest — every field is an
immutable handle, so duplicating the handle shares rather than mutates.
`World`/`ComponentStorage`/`ComponentRegistry` do exactly this.

### Verified parser / API gotchas (2026-11 session)

Sharp edges of the installed toolchain, each confirmed by a `monad check` probe
(a buffer is staged as a real `.mo` in the moot, so `use` resolution is the
real thing). Non-obvious enough to have cost real time — do not re-derive them.

| Gotcha | Correct form |
|---|---|
| `#[derive Copy]` without `use std::derive {}` | **silent no-op**; the type stays affine. Always `use std::derive {}`. |
| `match x with { ... }` / `match x of { ... }` | unsupported. Use `match x { ... }`. |
| `{ x with f := v : T }` (type-ascribed `with`) | parse error. Bind first: `let s2 : T := { s with f := v }`. |
| `[Monad M]` written *after* a `{A : Type}` binder | parse error. Constraints come first: `def f [Monad M] {A : Type} ...`. |
| `fn` at top level | not a declaration form. Use `def`. |
| `U64.to_u64` | does not exist. Up-cast is `I64.to_u64`; down-cast is `U64.to_i64`. |
| `use std::list {List.length}` / `{List.get}` / `{List.reverse}` / `{List.append}` | error — those are **ambient** (`List.get`/`List.length` in `init::list`; `List.append`/`List.map`/`List.first`/`List.is_empty` in the prelude), so importing them from `std::list` says `std::list declares no List.length`; just call them. `List.any`/`List.all`/`List.filter`/`List.sort_by`/`List.contains_by` DO live in `std::list` and must be imported. |
| `Array A` named in a mote | not `pub` in `std::array`; use `List`/`HashMap`. |
| a `Pair` / `Option.some` / `match`-bound binder read twice | affine error (the binder's type is abstract). Destructure or re-bind once; or ascribe (`let l : Loc := loc`); or return a named `Copy` struct instead of a `Pair`. |
| a raw `List`/`HashMap` binder read twice | affine error. Thread it once; `Shared.of` it; or `Clone.clone (Shared.of x)` for a second owner. |
| `use lib::{Entity}` (crate root) | must name the **submodule** (`use lib::ecs {Entity}`); the root declares no such name. |
| two files with the same `#[test]` name | test-driver `qualify_modules failed`; keep test names unique per module. |
| calling a class **DEFAULT** method (`MonadState.get_map`/`modify`) that your instance omits | fails at LLVM **lowering** with `use of undefined value '@modify_get'` — AFTER `check` passes. The compiler splices the default body and it references the class-level method name. Declare `modify`/`get_map` in your own instance (see `world_m.mo`). |
| an INLINE application of a `[Constraint]`-bearing def used as an **argument** (e.g. `WorldM.run_state (WorldM.put w) s`) | compiles to a broken partial shim; the test driver dies `driver exited -1` with no diagnostic (`check` is clean). Hoist it into a top-level `def` or a typed `let` first. |
| reaching a DEPENDENCY's module | `use lib::...` always means the **current** mote's own root. A dependency is reached by its `mote.toml` **dependency key**: `use forge_core::ecs {...}`. |
| a `[dependencies.forge-core]` key with a hyphen | the key is what `use` must spell, and a hyphen is not an identifier (`use forge-core::...` is a parse error). Key it `[dependencies.forge_core]` (path stays `../forge-core`) and write `use forge_core::...`. |
| `#[derive Copy Clone Debug]` on an **enum** | the Copy/Clone derive *macros* must be imported by name: `use std::derive {derive_copy, derive_clone, derive_debug}`. An empty `use std::derive {}` is enough for a *struct* (the in-scope `Copy`/`Clone` class names substitute) but on an enum it fails with `derive_clone is not imported`. |

### The dev shell must provide a STATIC Boehm GC

`monad run`/`test` link Boehm GC **statically** on Linux
(`-Wl,-Bstatic -lgc -Wl,-Bdynamic`, toolchain `llvm/src/link.mo`), so the
link needs `libgc.a`. Plain `pkgs.boehmgc` (from the pinned
`devenv-nixpkgs`) ships only the shared object, which is what produced:

```
ld.bfd: cannot find -lgc
ld.bfd: have you installed the static version of the gc library ?
```

`devenv.nix` therefore installs `pkgs.boehmgc.override { enableStatic = true; }`
instead of `pkgs.boehmgc`; its `-L` reaches clang through the shell's
`NIX_LDFLAGS`. **Always build and test inside `devenv shell`** — that is also
what the toolchain's own packaging does.

```
devenv shell -- monad check -w
devenv shell -- monad test -w          # links + runs
```

`monad check` alone works outside the shell (it never links), so a plain
`monad check` is fine for a quick type-only pass.

`monadup doctor` does NOT catch this: it sees `libgc.so` and reports the GC as
present, while the failure is a link-time `cannot find -lgc`. The only reliable
gate is `devenv shell -- monad test`.

### Fixed: the old "gaps" and the blocking bug

| Old plan claim | Verified status |
|---|---|
| **Gap 1**: `Map` class broken → use `List (Pair String Any)` | **Fixed.** `Map.insert`/`lookup`/`empty` over `HashMap`/`BTreeMap` check and dispatch. |
| **Gap 3**: field access `.x` unusable → use `match` | **Fixed.** `p.x`, `o.inner.v`, `{ p with x := 9 }` all work. |
| **Gap 2**: no linear/affine enforcement | **Inverted.** Affine *is* enforced; linear `!`/`%` annotations parse but are dropped. |
| "Any-boxed struct reconstruction corrupts a sibling field" | **Fixed.** Re-ran the repro under `monad eval`: an unrelated `free_ids` list now holds exactly 1 entry, not the duplicated 2. |
| `Result` has no `Monad` instance | **Fixed.** `instance Monad (Result E)` is in the prelude. |
| "no real parallelism in monad yet" | **Stale.** `std::concurrent` ships real 1:1-pthread `forkIO`/`await_fiber`, `all`/`race`/`scoped`, and MVar `Channel`s (compiled backend only). |

### Monad transformers ship

`use init::transformers` (opt-in, not re-exported from `init`'s hub):

| Transformer | Shape | Notes |
|---|---|---|
| `StateT S M A` | `S -> M (Pair S A)` | `get`/`put`/`modify`, `run`/`eval`/`exec`, `lift` |
| `ReaderT R M A` | `R -> M A` | `ask`/`asks`/`local` |
| `ResultT E M A` | `M (Result E A)` | `= ExceptT`; `throw`/`catch`/`map_error` |
| `OptionT M A` | `M (Option A)` | short-circuits on `none` |
| `WriterT W M A` | `M (Pair W A)` | `tell`/`listen`/`censor` |
| `IdentityT M A` | `M A` | pass-through |

Each has `Monad` over any `[Monad M]` base, so a stack resolves one level at
a time down to `Id`/`IO`. `MonadState` (prelude, keyed on the monad head)
provides `get`/`set`/`modify`/`modify_get`/`get_map` for `do` blocks.

Caveat: instance resolution is a **run-time** step, so a missing instance
type-checks and then fails with `unresolved global:`. Exercise every stack
with a `#[test]`, don't just `check` it.

### Efficient data structures

| Type | Module | Cost / notes |
|---|---|---|
| `Array A` | `std.array` | native-backed; **O(1)** `length`/`get`; `Array A` **is `Copy`** — but not `pub`, so a mote cannot name it (see gotchas) |
| `ArrayBuilder A` | `std.array` | mutable fill under `IO` (`set_in_place` O(1) compiled), then `freeze` |
| `HashMap K V` | `std.map` | 256-bucket chaining; needs `[Hashable K, BOrd K]` |
| `BTreeMap K V` | `std.map` | AVL, ordered folds |
| `Ref A` | `std.ref` | shared mutable cell; `Ref.update` is **atomic** (fiber-safe); `Ref A` is `Copy` |
| `ByteBuf` | `std.bytebuf` | C-addressable byte buffer (`#[extern "c"]`) |

`#[derive Hashable]` is **not** a derive backend that ships (only `BEq`,
`BOrd`, `Debug`, `Lens`, `Copy`, `Clone` are registered). Key maps by a
`Copy` id (`U64`) rather than by a derived-hash struct.

### The F64 surface is tiny — forge-math supplies the rest

`init::number` gives `F64` only `+ - * /` and `beq`/`lt`/`gt` (all `#[native]`:
`f64_add`/`sub`/`mul`/`div`/`eq`/`lt`/`gt`), plus `F64.to_string`. **There is no
`sqrt`, `sin`, `cos`, `abs`, `floor`, `tan`, and no integer<->float conversion
of any kind.** Float literals (`3.14159`, and `0.5` for halving) do work.

`motes/forge-math/src/num.mo` therefore builds the missing layer out of the
four operators and the comparisons: `f64_abs`, `f64_min`/`f64_max`/`f64_clamp`,
a **Newton-Raphson `f64_sqrt`** (exact for a perfect square — the tests assert
exact values), and a Maclaurin `f64_sin`/`f64_cos` after range reduction to
`|x| <= pi/2` (accurate to ~1e-8). `num` is private to forge-math; the public
`lib.mo` re-exports only the vectors/quaternion/matrix/intersection surface.

### Targets

`monad build --target wasm32-unknown-unknown` (web, JS imports) and
`wasm32-unknown-wasip1` (wasi) both exist. `motes/web_wasm` provides the
browser boundary: `Dom.*`, `Fetch.*`, `Worker.*`, `Clipboard.*`, `Clock`,
`Storage`, `Console`, plus a `jsgen`-based loader generator. There is **no
WebGL/WebGPU yet** — WebGL lands behind `forge-render` (Phase 8).

`MLIR`/GPU: monad's plan references an MLIR-based backend and a `Buf E`
heap kind (`runtime/src/runtime_core.c`, `plans/bootstrapping/mlir-codegen.md`).
Not here yet; GPU codegen is a future `forge-render` backend.

## Workspace structure

```
forge/
├── mote.toml                    # [workspace] members = ["motes/*"]
├── devenv.nix
└── motes/
    ├── forge-core/               # ECS, WorldM transformer stack, commands, query
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo            # re-exports
    │       ├── ecs.mo             # Entity, ComponentId, Column, Archetype, World
    │       ├── world_m.mo         # WorldM = StateT World M; Monad/MonadState
    │       ├── commands.mo        # Command, CommandBuffer, flush (WorldM)
    │       ├── query.mo           # Query, iteration, Changed filter
    │       └── tests/
    │           ├── ecs_tests.mo
    │           ├── ecs_mutation_tests.mo
    │           ├── world_m_tests.mo
    │           ├── commands_tests.mo
    │           ├── query_tests.mo
    │           └── change_detection_tests.mo
    ├── forge-math/               # Vec2/3/4, Quat, Mat3/4, intersection
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── vec.mo
    │       ├── quat.mo
    │       ├── mat.mo
    │       ├── intersect.mo
    │       └── tests/math_tests.mo
    ├── forge-schedule/           # stages, systems over WorldM, fixed timestep
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── schedule.mo
    │       ├── system.mo
    │       └── tests/schedule_tests.mo
    ├── forge-scene/              # transform hierarchy, spawn templates
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── scene.mo
    │       └── tests/scene_tests.mo
    ├── forge-reactive/           # Signal, EventStream over Ref + WorldM
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── reactive.mo
    │       ├── event.mo
    │       └── tests/reactive_tests.mo
    ├── forge-render/             # backend-agnostic render interface + soft backend
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── command.mo        # RenderCommand, Camera, MeshHandle, ...
    │       ├── extract.mo        # World -> List RenderCommand
    │       ├── backend.mo        # Renderer interface
    │       ├── soft.mo           # headless/soft backend (records commands)
    │       └── tests/render_tests.mo
    └── forge-app/                # App builder, plugins, IO main loop
        ├── mote.toml
        └── src/
            ├── lib.mo
            ├── app.mo
            ├── plugin.mo
            └── tests/app_tests.mo
```

Each mote depends on `forge-core` (and its own extra deps) via `path`.

## Verified end-to-end (2026-11-11)

Everything in Phases 1-2 was verified against the installed toolchain
`monad 38e2790` (`~/.monad/downloads/nightly-2026-11-11-38e27906`), from the
forge root, in the `devenv` shell:

```
monad check -w                     # 25 files, 0 errors
monad test -w                      # 152/152 tests passed
```

By mote: forge-core 40 (13 in-`ecs` unit tests, 4 change-detection, 3 commands,
5 ECS mutation, 4 ECS shape, 5 query, 6 `world_m`), forge-math 75 (12 `num`,
12 `vec`, 9 `quat`, 14 `mat`, 17 `intersect`, 11 cross-module); forge-schedule 37
(14 `system`, 12 `schedule`, 11 cross-module). `ecs.mo` alone also reports `ok` under a plain
`monad check` outside the shell.

**`monad check` is not the gate.** Of the failures that had to be fixed here,
one (`monad check`) was a type error; the other three type-checked and only
failed under `monad test`, at LLVM lowering or at run time:

- a class-default method (`MonadState.get_map`) spliced into an instance, whose
  body referenced `@modify_get` — an undefined symbol at lowering;
- an inline `[Constraint]`-bearing call used as an argument
  (`WorldM.run_state (WorldM.put w) s`) — a miscompiled partial shim, driver
  `exited -1` with no message;
- my first hand-written `get_map`, which returned the value instead of the
  value *paired with the threaded state*, so the driver destructured a
  non-constructor.

Every transformer-stack path is now executed by `world_m_tests.mo`, so a
regression in any of these three shapes fails loudly again.

## Implementation phases

### Phase 0: Toolchain re-baseline (P0) — **done**

- [x] Re-verify every old "gap"/"blocking bug" against the installed
      toolchain; record results in "Toolchain baseline".
- [x] Confirm the affine rule and its three escape hatches.
- [x] Confirm the old Any-boxed sibling-corruption bug is gone (`monad eval`).

### Phase 1: forge-core — affine-safe ECS on efficient structures (P0) — **done**

**Mote:** `motes/forge-core/`

As built (and verified: see "Verified end-to-end" above):

1. `src/ecs.mo` — the data model. One column per component, rows strictly
   parallel to an archetype's sorted component ids.
   - `Entity { id, generation }`, `ComponentId { id : I64 }`, `Loc
     { archetype, row }`, `Freed { id, generation }`, `Column { data : List Any,
     len : U64 }` — `#[derive Copy Clone ...]` (all-scalar, except `Column`
     whose single `List Any` is only ever read).
   - `ComponentRegistry { by_name : HashMap String I64, by_id : HashMap I64
     String, next : I64 }` interns each component name to a dense `I64` once.
   - `Archetype { key : String, ids : List ComponentId, columns : List Column,
     entities : List Entity }` — `key` is the canonical (sorted) id list
     rendered as a string, so a `HashMap` indexes archetypes in O(1).
   - `ComponentStorage { archetypes, archetype_index, entity_location : HashMap
     U64 Loc, free_ids : List Freed, next_id, clock, last_changed : HashMap U64
     (HashMap I64 U64), registry }` and `World { storage }`.
   - **`Array` is not usable**: the installed `std::array` declares `Array`
     without `pub`, so a mote cannot name it. Columns are `List Any` with an
     O(1) `len`. (Replace with `Array` if it ever becomes public — the column
     API is the only surface that would change.)
   - **`Copy` policy:** `ComponentStorage`/`World`/`ComponentRegistry` carry a
     **hand-written identity `instance Copy`** (`Pair.pair x x`) — every field
     is an immutable handle, so the duplicate shares. `Column`/`Archetype`
     derive `Copy` (they satisfy the affine gate; nobody elaborates
     `Copy.copy` on them, and a derived copy of a `List` field could not).
   - **No `Pair` in the result position.** Multi-field results are named
     monomorphic `Copy` structs — `Interned`, `InternedAll`, `Located`,
     `Spawned`, `Pushed`, `Moved`, `RemoveResult`, `SetResult`, `Alloc` — because
     a `Pair`'s two halves cannot both be read under the affine rule.
   - Pure operations: `spawn` / `despawn` / `insert_component` /
     `remove_component` / `set_component` / `get_component` /
     `get_component_named` / `changed_since` / `mark_changed`. They are pure
     `World -> World` (or `-> Spawned`/`-> SetResult`); the `WorldM` wrappers
     are the app's concern (Phase 2 / Phase 4), not the model's.
   - Archetype migration finds-or-creates the archetype for the new component
     set, moves the row, and updates `entity_location`.
   - Row removal is **swap-remove**: the last row fills the freed slot and the
     moved entity's location is rewritten in one place, so despawn/insert/remove
     stay O(1) in the archetype.
   - Non-`Copy` recursive helpers take reused arguments as `Shared` (the
     `std/map.mo` pattern) or take a second owner via
     `Clone.clone (Shared.of x)`.
2. `src/world_m.mo` — the transformer stack (Phase 2).
3. `src/commands.mo` — `Command` sum type, `CommandBuffer`, `Commands`, and
   `flush : World -> CommandBuffer -> World`:
   `commands_spawn` / `commands_despawn` / `commands_insert` / `commands_remove`.
4. `src/query.mo` — `query_iter` / `query_entities` / `row_select`, plus
   `ChangedFilter { key : String, last_seen : U64 }` and
   `passes_changed_filter`.
5. Tests: the three previously "blocked" files (`ecs_mutation_tests`,
   `change_detection_tests`, and the query tests) are folded back into the
   normal suite and are green; the stale "blocked by toolchain bug" headers are
   gone.

### Phase 2: forge-core — the WorldM transformer stack (P0) — **done**

**Mote:** `motes/forge-core/`

The flexibility requirement: systems are described as computations, not as
`World -> World` functions, so the same system runs purely in a test, over
`IO` in the app, and over `ResultT String IO` when fallible.

```monad
use init::transformers {StateT}

/// A world-threading computation over ANY base monad M.
pub type WorldM (M : Type -> Type) (A : Type) { mk (un : StateT World M A) }
```

1. `WorldM.run` (to the underlying `StateT`) and `WorldM.run_state (m) (w) :
   M (Pair World A)`.
2. `WorldM.get` / `WorldM.put` / `WorldM.modify` / `WorldM.lift` (delegating
   to `StateT`).
3. `instance [Monad M] Monad (WorldM M)` and `instance [Monad M] MonadState
   (WorldM M)`. The `MonadState` instance **re-declares `modify` and
   `get_map`** even though they are class defaults: omitting them makes the
   compiler splice the default body, which references the class-level
   `modify_get` and dies at LLVM lowering (see the gotchas table).
4. `type PureWorld A { mk (run : WorldM Id A) }` and
   `PureWorld.run (m : WorldM Id A) (w : World) : Pair World A`. (`run` takes
   a `WorldM Id A`, not a `PureWorld A`.)
5. `AppWorld` / `FallibleWorld` (`WorldM IO` / `WorldM (ResultT String IO)`)
   are **deferred** to Phase 4/7, where a system actually needs them.

**Verified end-to-end:** `motes/forge-core/src/tests/world_m_tests.mo`
executes every stack path (6 tests): `bind` reading the world, `.run_state`
preserving it, `put`, `modify`, the `MonadState.get_map` class method, and the
`PureWorld` alias. **This is the gate that matters** — the `Monad`/`MonadState`
instances type-checked long before they ran, and three separate codegen/lowering
bugs only appeared when the test was executed.

### Phase 3: forge-math (P1) — **done**

**Mote:** `motes/forge-math/`

As built (52 unit tests + 11 integration tests, all green):

- `src/num.mo` — the F64 layer above (`f64_sqrt`/`sin`/`cos`/`abs`/`min`/`max`/
  `clamp`, `pi`/`tau`, `f64_approx`). Not exported from `lib.mo`.
- `src/vec.mo` — `Vec2`/`Vec3`/`Vec4` as monomorphic `#[derive Copy Clone Debug]`
  structs with `.x`/`.y`/`.z`/`.w`. Operations are suffixed by size (`v3_add`,
  `v2_dot`, ...) rather than class-based. `v3_cross`, `v3_normalize`,
  `v3_reflect`, `v2_perp`, `v4_to_v3` (perspective divide as a value).
- `src/quat.mo` — `Quat` (`w = cos(theta/2)`); `quat_from_axis_angle`,
  `quat_mul` (Hamilton), `quat_rotate` (`v + 2 q_v x (q_v x v + w v)`),
  `quat_rotate_inv`, `quat_normalize`, `quat_slerp` (**nlerp** — there is no
  `acos`), `quat_same_rotation` (sign-insensitive), `quat_angle`.
- `src/mat.mo` — `Mat3`/`Mat4` stored as **columns of `VecN`** (column-major,
  which is what a GPU wants and makes `m * v` a weighted column sum).
  `mat4_identity`, `translate`, `scale`, `mat4_from_quat`,
  `mat4_rotate_axis_angle`, `mat4_trs` (`T*R*S`), `mat4_transform_point` /
  `_dir`, `mat4_mul`, `mat4_mul_vec4`, `mat4_transpose`, `mat4_perspective`,
  `mat4_orthographic`, `mat4_look_at`, `mat4_to_mat3`. **One stated convention:**
  right-handed, depth to `[-1, 1]` (OpenGL).
- `src/intersect.mo` — `Ray`/`Plane`/`AABB`/`Sphere`;
  `ray_intersects_sphere`, `ray_intersects_aabb` (slab method),
  `aabb_intersects_aabb`, `sphere_intersects_sphere`, `ray_intersects_plane`,
  `plane_distance`, `aabb_contains`.
- `src/tests/math_tests.mo` — the cross-module pipeline: MVP composition, TRS
  ordering, a projection landing a point at NDC center, slerp, and camera-ray
  picking.
- `src/lib.mo` re-exports the whole surface (not `num`).

**Acceptance met:** `monad check -w` clean, `monad test -w` green (see
"Verified end-to-end").

### Phase 4: forge-schedule (P2) - **done**

**Mote:** `motes/forge-schedule/` (depends on `forge-core`)

As built (37 tests: 14 `system`, 12 `schedule`, 11 in `tests/schedule_tests.mo`):

- `src/system.mo` - the 12-stage `ScheduleState` enum with `stage_ordinal`
  (pipeline order, not declaration order), `stage_name`, `all_stages`; the
  `System` record (`name`/`stage`/`reads`/`writes`/`run`); conflict analysis
  (`ids_overlap`, `systems_conflict`) and greedy batching (`batches`,
  `batch_count`); and the fixed-timestep `Clock` (`clock_advance` -> `{clock,
  steps}`).
- `src/schedule.mo` - the `Schedule` builder (`add_system`, `add_system_to`),
  stage queries, and the runners: `run_stage`, `run_schedule[_pure]`,
  `run_fixed_steps`. Plus the `Time` resource (`time_advance` folds
  `clock_advance` and carries `fixed_steps`).
- `src/lib.mo` re-exports both; `src/tests/schedule_tests.mo` drives the
  pipeline (frames, fixed steps, ordering, batching-as-metadata).

**Two deliberate deviations from the plan**, both because the pure schedule is
what `monad test` can actually run:

1. **`System` carries `WorldM Id Unit`, not `WorldM IO Unit`.** Everything is a
   pure `World -> World` schedule, so it runs (and is tested) with no IO. The
   `WorldM IO` app variant is Phase 7.
2. **Systems run in registration order within a stage, sequentially.** The
   conflict-based `batches` are computed and tested, and exposed as
   `stage_batches` metadata, but *executing* a batch on fibers -- with the
   `CommandBuffer` handle a `WorldM IO` system needs to enqueue anything --
   is Phase 7's job. A pure reorder would also be wrong: a later system may
   depend on an earlier one's side effect with no declared read/write overlap.

### Phase 5: forge-scene (P3)

**Mote:** `motes/forge-scene/` (depends on `forge-core`, `forge-math`)

1. `Transform` (translation `Vec3`, rotation `Quat`, scale `Vec3`) — derive
   `Copy`.
2. `Parent`/`Children` components.
3. `GlobalTransform` (computed `Mat4`).
4. Propagation system: top-down, dirty-flag, as a `WorldM IO` system.
5. Spawn templates: `SpawnTemplate := WorldM M Entity`.

### Phase 6: forge-reactive (P4)

**Mote:** `motes/forge-reactive/` (depends on `forge-core`)

1. `Signal A` built on `Ref` (atomic, fiber-safe) + a changed flag; keep the
   dependency list minimal.
2. `signal_map`, `signal_zip`, `signal_fold`.
3. `EventStream A { buffer : Ref (List A), max_per_frame : U64 }` with
   `EventWriter`/`EventReader` and frame-budgeted processing.

### Phase 7: forge-app (P5)

**Mote:** `motes/forge-app/` (depends on all)

1. `App` builder, `Plugin` type.
2. `DefaultPlugins` list.
3. `App.run : IO Unit` — the main loop: cold → warm → command flush →
   fixed-update accumulator → update → render → present → cleanup.
4. Minimal demo: a single-system app that increments a counter resource.

### Phase 8: forge-render — backend-agnostic render interface (P6)

**Mote:** `motes/forge-render/` (depends on `forge-core`, `forge-math`,
`forge-scene`)

The whole point: **the core never knows which backend draws.** MLIR/GPU and
WebGL become backends behind this interface, not changes to the core.

1. `src/command.mo`: `RenderCommand` as a `#[derive Copy Debug]` data enum
   (`draw_mesh`, `set_camera`, `clear`, ...), `Camera`, `MeshHandle`,
   `MaterialHandle`, `Color`.
2. `src/extract.mo`: `extract (world : World) : List RenderCommand` — a pure
   read of the `World` at the `render_s` stage. No backend types leak in.
3. `src/backend.mo`: the `Renderer` interface — `submit : List RenderCommand
   -> IO Unit`, `present : IO Unit`, `resize : I64 -> I64 -> IO Unit`,
   `shutdown : IO Unit`.
4. `src/soft.mo`: a headless/soft backend that records commands (for tests
   and CI); this is what makes the pipeline testable without a GPU.
5. Tests: extract produces the expected commands for a scene; the soft
   backend records them.

**Later backends (no core change):**
- **WebGL**: a `web_wasm`-backed `Renderer` — WebGL context via a new
  `web_wasm` extern family + `jsgen` glue, drawing `RenderCommand`s.
- **GPU/MLIR**: a `Renderer` whose `submit` lowers to monad's MLIR/GPU
  backend (`Buf E`, kernel dispatch) once that lands.

## What is deferred

- **Physics (P11)**: GJK/EPA with F64 — deferred (solver complexity).
- **Audio (P10)**: native audio backend — deferred.
- **Networking (P12)**: UDP transport + rollback — deferred.
- **UI (P9)**: retained-mode tree + flexbox — deferred (depends on rendering).
- **Input/Window (P6)**: native OS bindings — deferred; the `Renderer`
  interface already carries `resize`, and `web_wasm` provides DOM events for
  the web path.
- **Editor (P13)**: depends on UI — deferred.
- **GPU/WebGL/MLIR backends**: interface is Phase 8; backends land when
  monad's MLIR/GPU support and a `web_wasm` WebGL extern family exist.

## TDD approach

Each phase: write failing `#[test]` defs first, implement until `monad test`
passes. Run from the forge root:

```bash
monad test -w                            # all motes
monad check -w                           # typecheck the whole workspace
monad test motes/forge-core/src/tests/   # a single directory
monad check motes/forge-math/            # a single mote
```

Because instance resolution is a run-time step, **`monad test` is the real
gate** — a missing `Monad`/`MonadState` instance type-checks and only fails
when executed. Keep every transformer-stack path exercised by a test.

## Tasks

- [x] Phase 0: toolchain re-baseline (gaps fixed, affine rule recorded, old bug confirmed gone)
- [x] Phase 1: forge-core affine-safe ECS (`Entity`/`ComponentId`/`Column`/`Archetype`/`World`, `spawn`/`despawn`/`insert`/`remove`/`set`, change ticks; 13 in-`ecs` tests + 5 test files, all green)
- [x] Phase 2: forge-core `WorldM` transformer stack (`StateT World M`, `Monad`/`MonadState`, `PureWorld` alias; exercised by `world_m_tests.mo`)
- [x] Phase 3: forge-math (`num` F64 layer, `Vec2/3/4`, `Quat`, `Mat3/4`, `Ray`/`Plane`/`AABB`/`Sphere`; 52 unit + 11 integration tests)
- [x] Phase 4: forge-schedule (`ScheduleState`/`System`/`Schedule`, conflict batching as metadata, fixed timestep + `Time`); systems are the PURE `WorldM Id` (37 tests)
- [ ] Phase 5: forge-scene (transform hierarchy, propagation, spawn templates)
- [ ] Phase 6: forge-reactive (Signal/EventStream over `Ref` + `WorldM`)
- [ ] Phase 7: forge-app (builder, plugin, IO main loop, minimal demo)
- [ ] Phase 8: forge-render (RenderCommand, extract, Renderer interface, soft backend)
