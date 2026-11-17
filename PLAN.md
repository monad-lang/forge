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
`Storage`, `Console`, plus a `jsgen`-based loader generator.

**WebGL (2026-11-17): landed as Phase 9a.** `web_wasm` at the pin
`77ed9468` ships the GL surface (`src/gl.mo`, `src/canvas.mo`, uploads over
`std::buf`). Forge consumes it from ONE web-only mote, `motes/forge-webgl`
(the renderer), and ONE web-only module, `forge_app::web` (the frame
driver); a game depends on `forge_app` alone. The 2026-11-16 note that put
everything in a forge-app bin is superseded: the bin is now only the demo.

Toolchain facts measured on the way (the rest are in "Gaps in monad and
its motes" below):

- **Member-scoped commands cannot see a workspace git dependency.**
  `web_wasm` is a `[workspace.dependencies]` entry and the lock is the
  root's `mote.lock`, but `monad check motes/forge-webgl` (or
  `monad test motes/forge-app`) fails with "not in mote.lock":
  `Build.verify_home` reads the MEMBER's directory. Run `-w` from the root.
- **A nested struct literal infers no field types.** `Result.ok { ... }`
  inside a `match` arm inside a `do` block never reaches the checker with an
  expected type, so the fields become bare type variables and the affine
  gate fires before a `Copy` instance can be selected. Use a named
  constructor def. The `<-` form has the same problem (gap G3).

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
    │       ├── mesh.mo           # MeshData + quad/box/disc/cylinder
    │       ├── material.mo       # Material, TextureDesc, Assets tables
    │       ├── plan.mo           # frame_plan: commands + assets -> FramePlan
    │       ├── pick.mo           # pick_entity
    │       └── tests/render_tests.mo
    ├── forge-webgl/              # WebGL executor of a FramePlan (web-only)
    │   ├── mote.toml             # targets = ["web"]
    │   └── src/
    │       ├── lib.mo
    │       ├── shaders.mo        # GLSL ES 1.00 flat + textured
    │       └── renderer.mo       # WebGlRenderer: programs, uploads, submit
    └── forge-app/                # App builder, plugins, IO main loop
        ├── mote.toml             # targets = ["web"]; bin forge-app-web
        └── src/
            ├── lib.mo
            ├── app.mo            # App, app_frame / app_frame_dt, CameraRig
            ├── plugin.mo
            ├── input.mo          # Input: keyboard/pointer state as a world resource
            ├── web.mo            # forge_app::web: browser frame driver (web-only)
            ├── main.mo           # demo bin
            └── tests/app_tests.mo
scripts/web-build.sh               # wasm build + host JS into target/web
scripts/web-serve.sh               # build + serve for a browser (README.md)
scripts/web-smoke.sh               # build + stub-GL smoke in Node
tests/web/forge_webgl_smoke.mjs
web/                               # index.html + floor texture for the demo
```

Each mote depends on `forge-core` (and its own extra deps) via `path`.

## Verified end-to-end (2026-11-11)

Everything in Phases 1-2 was verified against the installed toolchain
`monad 38e2790` (`~/.monad/downloads/nightly-2026-11-11-38e27906`), from the
forge root, in the `devenv` shell:

```
monad check -w                     # 39 files, 0 errors
monad test -w                      # 241/241 tests passed
```

By mote: forge-core 40 (13 in-`ecs` unit tests, 4 change-detection, 3 commands,
5 ECS mutation, 4 ECS shape, 5 query, 6 `world_m`), forge-math 75 (12 `num`,
12 `vec`, 9 `quat`, 14 `mat`, 17 `intersect`, 11 cross-module); forge-schedule 37
(14 `system`, 12 `schedule`, 11 cross-module); forge-scene 13 cross-module;
forge-reactive 31 (14 `reactive`, 11 `event`, 6 cross-module); forge-render 29
(7 `command`, 8 `backend`, 2 `soft` (re-exported), 13 cross-module);
forge-app 15 (8 `app`, 2 `plugin`, 5 cross-module). `ecs.mo` alone also reports `ok` under a plain
`monad check` outside the shell.

**Re-verified 2026-11-17** (`monad 7a9b25f`, after Phase 9a): `monad check
-w` 48 files, 0 errors (forge-webgl and `forge_app::web` included);
`monad test -w` **312/312** — forge-core 47, forge-math 91, forge-schedule
42, forge-scene 15, forge-reactive 35, forge-render 60, forge-app 22.
`scripts/web-smoke.sh`: the demo builds for `wasm32-unknown-unknown` and
passes the stub-GL smoke in webgl2, webgl1 and no-WebGL modes.
After web input (same day): forge-app **37/37** (+14 `input.mo`, +1
`app_frame_input`), so 327 in all; the other motes are unchanged. The
smoke also asserts the keyboard move, and `scripts/web-serve.sh` serves
`app.wasm` as `application/wasm`.

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
5. `AppWorld` (`WorldM IO`, run with `AppWorld.run`) and `FallibleWorld`
   (2026-11-17, both executed by `world_m_tests.mo`). **`FallibleWorld` is
   NOT `WorldM (ResultT String IO)`**: that stack type-checks but
   `Monad.pure` through a transformer over a transformer is miscompiled
   (gap G1), so `FallibleWorld A` is its own monad over
   `World -> IO (Result String (Pair World A))`, with `lift` from
   `WorldM IO`, `fail`, `of_result`, `get`, `modify`.

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

### Phase 5: forge-scene (P3) - **done**

**Mote:** `motes/forge-scene/` (depends on `forge-core`, `forge-math`)

As built (13 tests in `src/tests/scene_tests.mo`):

- `src/scene.mo` - `Transform` (translation/rotation/scale), `Parent`,
  `GlobalTransform`, all `#[derive Copy Clone Debug]`; the component-name
  constants (`forge.transform`/`forge.global_transform`/`forge.parent`);
  spawners (`spawn_transform`, `spawn_transform_child`, `spawn_child_at`);
  typed accessors (`entity_transform`/`entity_global`/`entity_parent`); and
  the top-down propagation pass (`propagate_transforms`).
- `src/lib.mo` re-exports the surface.

Component values are boxed into the ECS as `Any`; the accessors unbox them
with a typed `let` (`match v { Any.any x => let t : Transform := x in t }`) --
the only route back from `Any`, which erases the payload type. Everything the
mote needs from a `World` goes through forge-core's public API
(`get_component_named`, `query_entities`); it never reaches into
`Archetype`/`ComponentStorage` internals, so a cross-crate field access is not
a hazard here.

**`Children` is not stored** (the plan listed it). Children are found by
reading every entity's `Parent`, which keeps one source of truth.
`propagate_transforms` builds a `parent id -> children` index in ONE pass
first (2026-11-17), so propagation is linear; the old per-node scan was
O(n^2).

**`#[terminating]` on the propagation recursion is load-bearing:** it descends
into a FILTERED child list, not a structural subterm, so the checker cannot
see the decrease. (A cyclic parent graph would therefore loop; component
chains are assumed acyclic, as in every ECS.)

**This phase found a real forge-core bug.** `archetype_swap_remove` moved the
swapped row's COLUMNS but not its ENTITY handle, so after any mid-list removal
`entities[row]` kept naming the departing entity -- and every walk by row index
(`query_iter`, forge-scene's `all_transformed`) returned the wrong entity. It
was invisible until forge-scene's tests exercised a depth-3 hierarchy: every
existing forge-core test either appended rows or removed the LAST one
(`archetype_truncate`), and a depth-2 parent/child case only ever appends, so a
single propagation looked correct while a grandchild was silently never
reached.
Fixed in `ecs.mo` (`copy_row` now copies the handle too), pinned by
`test_mid_list_swap_remove_moves_the_entity_handle`.

### Phase 6: forge-reactive (P4) - **done**

**Mote:** `motes/forge-reactive/` (depends on `forge-core` (path only), `std::ref`)

As built (31 tests: 14 `reactive`, 11 `event`, 6 cross-module):

- `src/reactive.mo` - `Signal A` (`value` + a `version` bumped per write);
  `signal_new`/`signal_get`/`signal_version`/`signal_set`/`signal_update`;
  `Derived A` (a recompute-on-read view) with `derived_get`;
  `signal_map`/`derived_map`/`signal_zip2`/`signal_zip3`/`signal_fold`.
- `src/event.mo` - `EventStream A` (a `Ref (List A)` + a per-frame budget);
  `event_send`/`event_pending`/`event_drain`/`event_drain_all`/`event_clear`.
- `src/lib.mo` re-exports both; `src/tests/reactive_tests.mo` drives them
  together (a budgeted drain feeding a signal, a derived chain, a zip).

**Everything is `IO`** (`std::ref`'s natives), and both types are
parameterized -- so neither is `Copy` (a parameterized type cannot have a
`Copy` instance) and both travel as `Shared (...)`; each accessor destructures
the handle exactly once. This is the same shape `init` uses for `ReaderT`'s
non-`Copy` environment.

**Two deliberate design choices, both simplifications of the plan:**

1. **`Derived` recomputes on read** instead of a subscription graph. A real
   graph needs mutable listener lists and set-time callbacks; a thunk that
   reads its sources is always current and needs no invalidation. `Memo`
   (`signal_memo`, 2026-11-17) is the cached form: last value + the source
   version it was computed at, recomputed only after a write.
2. **`EventStream` is one queue, not `EventWriter`/`EventReader` handles.**
   `event_drain` returns the batch under the budget; a per-reader cursor would
   be the next step if two consumers ever need independent views.

`event_drain`'s read-then-truncate is a `Ref.get` followed by a `Ref.set`,
NOT one atomic `Ref.update`: `Ref.update` returns the NEW value, so it cannot
hand back the prefix it removed. That is sound for one writer + one reader per
frame, which is the intended shape, and it is documented in the module.

### Phase 7: forge-app - App builder, plugin, IO main loop (P5) - **done**

**Mote:** `motes/forge-app/` (depends on all five others)

As built (15 tests: 8 `app`, 2 `plugin`, 5 cross-module):

- `src/plugin.mo` - `Plugin` = a name + an `IO Unit` setup, plus the named-only
  constructor. `Copy` (hand-written): a plugin is a value.
- `src/app.mo` - `App`, a PURE description (schedule + plugins + renderer +
  initial world + camera + clear colour + frame budget); the builder
  (`app_add_plugin`, `app_add_system`, `app_set_*`); and the loop
  (`app_step`, `app_run`).
- `src/tests/app_tests.mo` - the WHOLE stack on one path: forge-scene builds a
  meshed hierarchy, forge-render extracts it, the recording backend shows the
  frame came out `clear, set_camera, draw, present`.

`app_step` is, in order: `propagate_transforms` -> `run_schedule_pure` ->
`extract` -> `renderer_submit` + `renderer_present`. Those last two are the
only IO in the mote, and `App` itself is inert until `app_run` -- which is
exactly what makes the loop testable.

**Deviations from the plan:**

1. **`app_run` returns the final `World`**, not `IO Unit`. A caller that does
   not want it ignores it, and every frame's effect stays observable in a test.
2. **The fixed-timestep accumulator is wired in (2026-11-17), as
   `app_frame_dt`.** The clock is a `Time` resource IN the world (a singleton
   entity, `world_time`), advanced by `dt` each frame, and
   `run_schedule_timed` repeats `fixed_update_s` by the accumulated step
   count. The real clock source is the browser's rAF timestamps
   (`forge_app::web`). `app_run` still runs a fixed frame count with no clock.
3. **No `DefaultPlugins` list.** There is nothing in the stack a default set
   would have to register yet (the renderer and camera are plain `App` fields,
   not resources). It becomes meaningful once there are resource-bearing
   plugins to package.

### Phase 8: forge-render - backend-agnostic render interface (P6) - **done**

**Mote:** `motes/forge-render/` (depends on `forge-core`, `forge-math`, `forge-scene`)

The whole point: **the core never knows which backend draws.** `extract` turns
a `World` into a pure `List RenderCommand`, and a `Renderer` consumes it;
adding a GPU or WebGL backend is a new `Renderer` variant, not a core change.

As built (29 tests: 7 `command`, 8 `backend`, 2 `soft`, 13 cross-module):

- `src/command.mo` - `MeshHandle`/`MaterialHandle`/`Color`/`Camera`, and
  `RenderCommand` as a **payload-carrying `Copy` enum** (`clear_cmd`,
  `set_camera_cmd`, `draw_mesh_cmd`, `present_cmd`) with smart constructors
  and `command_kind`/`is_draw`/`count_draws`.
- `src/backend.mo` - the `Renderer` interface as an **enum** (`soft` records
  into a `Ref (List RenderCommand)`, `headless` drops), with `submit`,
  `present`, `resize`, `shutdown`, and inspection (`recorded`, `size`).
- `src/soft.mo` - thin named entry point for the recording backend
  (`soft::new`, `soft::recorded`).
- `src/extract.mo` - the `forge.mesh` component, its typed `Any` accessor, and
  `extract (world) (camera) (background) : List RenderCommand` =
  `clear, set_camera, draw* <, present>`. An entity is drawn iff it carries
  BOTH a mesh and a `GlobalTransform`.
- `src/tests/render_tests.mo` - the whole pipeline with no GPU: build a scene,
  extract, hand it to the soft backend, assert the recording.

**Two design points:**

1. `Renderer` is an **enum, not a record of closures**. A struct cannot hold a
   `-> IO Unit` field (`term_to_expr_value: unsupported term shape`); an enum
   also makes the backend choice exhaustive.
2. `extract` takes the `Camera` as a **plain argument** rather than reading a
   camera resource out of the world. Components are `Any` and a camera is a
   natural value for the caller (the app) to own; storing it would add an
   interning round trip for no benefit yet.

**Later backends (no core change):** a `web_wasm` WebGL `Renderer` variant, and
a GPU/MLIR one, exactly as the interface promises.

### Phase 9a: WebGL backend (P6b) - **done**

The design is `plans-monad/implementations/web-webgl.md` (Forge P3–P5).
As built (2026-11-17):

1. **forge-math picking.** `mat4_inverse : Option Mat4` (2x2
   sub-determinants), `mat4_to_list` (column-major, the `uniformMatrix4fv`
   layout), `ray_sphere_hit`/`ray_aabb_hit`/`ray_plane_hit : Option F64` with
   the `Bool` forms rewritten on top, and `screen_to_ray (inv_view_proj) (w)
   (h) (x) (y)` (top-left pixel origin). `num`'s `sin`/`cos`/`sqrt`/`pi` and a
   new `f64_of_i64` are now re-exported (a mesh builder needs them).
2. **forge-render data + the shared core.** `mesh.mo` (`MeshData`:
   interleaved `x y z u v`, CCW triangle indices; `mesh_quad`/`box`/`cube`/
   `disc`/`cylinder`, `mesh_bounds`), `material.mo` (`ShaderKind
   {flat, textured}`, `TextureDesc`, `Material`, and `Assets`: dense
   handle -> data tables), `plan.mo` (`frame_plan assets cmds : FramePlan` —
   clear, camera, resolved `DrawCall`s in order, unknown meshes skipped and
   counted, unknown materials -> flat white) and `pick.mo` (`pick_entity`:
   nearest hit of a ray against each drawable's local bounds).
   **`frame_plan` is the shared core:** every decision a backend could
   disagree on is made here, purely, and is natively tested. Packing moved
   to `Gl.f32_buf`/`i32_buf` (`std::buf`), so forge-render has no IO.
3. **`app_frame`.** `app_frame (a) (w) : Frame {world, commands}` is
   propagate -> schedule -> propagate -> extract; `app_step` is `app_frame`
   + submit/present (existing tests unchanged; a new one asserts the
   equivalence). `app_frame_dt` adds the clock; `app_plan` resolves against
   `App.assets`. The second propagate means a system's moves are drawn the
   same frame.
4. **`motes/forge-webgl`** (`targets = ["web"]`, no tests of its own):
   `WebGlRenderer` holds two GLSL ES 1.00 programs (work on WebGL1 and 2),
   per-mesh VBO/IBO (32-bit indices; setup fails clearly without
   `OES_element_index_uint`), per-texture `GlImage` polled each frame (a
   textured draw is drawn flat until its image is ready). `webgl_submit`
   executes a `FramePlan`; on context loss it draws nothing and the first
   frame after restore relinks and re-uploads everything.
5. **`forge_app::web`** (web-only, not re-exported by `lib.mo`):
   `web_mount app rig` / `web_dispatch` / `web_tick` are the bodies of the
   three loader exports. rAF timestamps -> `dt` (clamped to 0.25 s) ->
   `CameraRig` camera for the canvas aspect -> `app_frame_dt` -> `app_plan`
   -> `webgl_submit`; a canvas click picks against the last frame's world
   and sets `data-picked`. It drives frames through `web_wasm` directly
   (`Dom.on_frame`, `Keep`), not through oak.
6. **Demo + parity.** `src/main.mo`: a spinning cube with an orbiting
   cylinder and a spinning cap over a textured floor. Parity is structural
   (both backends consume the commands `frame_plan` resolves) and asserted
   natively (`test_soft_recording_and_plan_agree`); on the web side
   `scripts/web-smoke.sh` builds the bin for `wasm32-unknown-unknown` and
   runs `tests/web/forge_webgl_smoke.mjs` over monad's `stub_dom`/`stub_gl`
   in webgl2, webgl1 and no-WebGL modes.

7. **Input** (2026-11-17, after 9a). `forge_app::input` (native, tested):
   a pure `Input` (held / pressed / released keys by physical
   `KeyboardEvent.code`, pointer position and per-frame motion, buttons,
   wheel) folded from `InputEvent`s with `input_apply` and cleared per frame
   with `input_end_frame`; installed in the world as the `"forge.input"`
   singleton resource by `app_frame_input`, read by systems with
   `world_input`. `forge_app::web` registers one handler id for
   `keydown`/`keyup`/`blur` on `window` and
   `pointermove`/`pointerdown`/`pointerup`/`pointerleave`/`wheel` (no page
   scroll) on the canvas, prevents the scroll default for Space and arrows,
   and reads only the fields each event kind carries. The demo moves its
   hierarchy with WASD/arrows; the smoke asserts the move through the real
   loader.
8. **Browser run.** `scripts/web-serve.sh` builds into `target/web/` (via
   `scripts/web-build.sh`, shared with the smoke) with `web/index.html` and
   a generated checker `forge-floor.png`, and serves it on localhost.
   README.md has the instructions.

**Not done:** a manual check in a real browser (no browser in this
environment); `scripts/web-serve.sh` is the way to do it.

## What is deferred

- **Physics (P11)**: GJK/EPA with F64 — deferred (solver complexity).
- **Audio (P10)**: native audio backend — deferred.
- **Networking (P12)**: UDP transport + rollback — deferred.
- **UI (P9)**: retained-mode tree + flexbox — deferred (depends on rendering).
- **Input/Window (P6)**: native OS bindings — deferred; the `Renderer`
  interface already carries `resize`, and the web path has canvas resize
  (`webgl_resize`), click picking and keyboard/pointer/wheel input
  (`forge_app::input` + `forge_app::web`). Gamepad, touch gestures and
  pointer lock are not done.
- **Fiber-executed batches / per-reader event cursors**: still metadata
  (`stage_batches`) and a single queue; both need a consumer first.
- **`DefaultPlugins`**: nothing to register yet.
- **Editor (P13)**: depends on UI — deferred.
- **GPU/MLIR backends**: interface is Phase 8; they land when monad's
  MLIR/GPU support exists, as further executors of a `FramePlan`.

## Gaps in monad and its motes

Recorded in full, with repros and the workarounds above, in
`plans-monad/implementations/2026-11-17-forge-webgl-consumer-gaps.md`
(the earlier log is `2026-09-26-external-mote-gaps-for-forge.md`).

| # | Gap | Forge workaround |
|---|---|---|
| G1 | `Monad.pure` through `StateT S (ResultT E M)` is miscompiled | `FallibleWorld` is a hand-written monad |
| G2 | member-scoped commands miss a workspace git dep's lock | `-w` from the root only |
| G3 | a typed `let x : T <- ...` is still affine as a type variable | reuse moved into helpers with typed parameters |
| G4 | an unresolved `use` is only a warning (`check` says 0 errors) | the stale `use lib::schedule` is fixed |
| G5 | `web_wasm`'s `Node` and GL enums have no `Copy` | forge-webgl declares `Copy Node`; enums rebuilt per use |
| G6 | the web loader contract is oak-named and single-app (`Keep`) | forge exports `oak_mount`/`oak_dispatch_event`/a no-op `oak_tick` |
| G7 | web host JS and stubs are not shipped to consumers; the loader generator and the wasm build need undocumented env | `scripts/web-smoke.sh` reads them from a monad checkout at the pin; `devenv.nix` sets `MONAD_WEB_CC` |
| G8 | no `I64` -> `F64` in `init` | `f64_of_i64` in forge-math |
| G9 | `web_event`'s `WebEvent` cannot be named through `web_wasm`; trying breaks field access | one `WebEvent.current` getter per field in `forge_app::web` |
| G10 | no prefix `!` on `Bool` (misleading "expected '('") | `Bool.not` |

## TDD approach

Each phase: write failing `#[test]` defs first, implement until `monad test`
passes. Run from the forge root:

```bash
monad test -w                            # all motes
monad check -w                           # typecheck the whole workspace
monad test motes/forge-core/src/tests/   # a single directory
monad check motes/forge-math/            # a single mote
```

The web side has no native tests (a native binary cannot link WebGL
externs); it is gated by a wasm build plus the stub-GL smoke:

```bash
devenv shell -- scripts/web-smoke.sh     # needs a monad checkout (MONAD_SRC, default ../monad)
devenv shell -- scripts/web-serve.sh     # same build, served at http://localhost:8080
```

**Keep the monad pin current.** `mote.toml` tracks `branch = "main"` of
`https://github.com/monad-lang/monad.git` for `web_wasm`; `mote.lock`
holds the exact commit. `monad update` moves it to upstream's head; then
check that commit out in `../monad` and re-run the gates above. Checked
2026-11-17: upstream main is `77ed9468` (the newer commits in the private
fork are typechecker/proofs only).

The dev shell sets `MONAD_WEB_CC` to `clang-unwrapped`: nix's wrapped clang
injects hardening and glibc linker flags the wasm target rejects. A
member-scoped build cannot see the workspace's lock (gap G2), so the script
copies the root `mote.lock` into `forge-app`/`forge-webgl` for the build
and removes it after.

Because instance resolution is a run-time step, **`monad test` is the real
gate** — a missing `Monad`/`MonadState` instance type-checks and only fails
when executed. Keep every transformer-stack path exercised by a test.

## Tasks

- [x] Phase 0: toolchain re-baseline (gaps fixed, affine rule recorded, old bug confirmed gone)
- [x] Phase 1: forge-core affine-safe ECS (`Entity`/`ComponentId`/`Column`/`Archetype`/`World`, `spawn`/`despawn`/`insert`/`remove`/`set`, change ticks; 13 in-`ecs` tests + 5 test files, all green)
- [x] Phase 2: forge-core `WorldM` transformer stack (`StateT World M`, `Monad`/`MonadState`, `PureWorld` alias; exercised by `world_m_tests.mo`)
- [x] Phase 3: forge-math (`num` F64 layer, `Vec2/3/4`, `Quat`, `Mat3/4`, `Ray`/`Plane`/`AABB`/`Sphere`; 52 unit + 11 integration tests)
- [x] Phase 4: forge-schedule (`ScheduleState`/`System`/`Schedule`, conflict batching as metadata, fixed timestep + `Time`); systems are the PURE `WorldM Id` (37 tests)
- [x] Phase 5: forge-scene (`Transform`/`Parent`/`GlobalTransform`, typed `Any` accessors, top-down propagation; 13 tests). Fixed a forge-core swap-remove bug this phase surfaced.
- [x] Phase 6: forge-reactive (`Signal`/`Derived` over `Ref`, `EventStream` with a per-frame budget; 31 tests). All IO; both types travel as `Shared`.
- [x] Phase 7: forge-app (`App` builder, `Plugin`, `app_step`/`app_run` IO loop, demo; 15 tests).
- [x] Phase 8: forge-render (`RenderCommand` enum, `extract`, `Renderer` enum + soft/headless backends; 29 tests). The core knows no backend.
- [x] Phase 9a: WebGL backend (`app_frame`/`app_frame_dt`, `MeshData`/`Assets`/`frame_plan`, wasm-only `forge-webgl`, `forge_app::web` driver, picking, parity + stub-GL smoke); browser check outstanding
- [x] Deviations closed: `AppWorld`/`FallibleWorld`, fixed timestep in the loop, linear transform propagation, memoized `Memo`
- [x] Web input: `forge_app::input` (`Input` resource, `app_frame_input`) + keyboard/pointer/wheel listeners in `forge_app::web`; demo WASD movement; browser run setup (`scripts/web-serve.sh`, `web/`, README.md)
