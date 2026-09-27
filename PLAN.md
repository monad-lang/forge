# Forge — Game Engine Implementation Plan

## Summary

Implement the Forge game engine

### Workspace setup

A bare `mote.toml` with just `[mote]` (name/version/edition) is enough for a
leaf mote. Cross-mote dependencies still use explicit path entries:
```toml
[dependencies.forge-core]
path = "../forge-core"
```

If you want Forge to track a **live local `../monad` checkout** instead of
whatever nightly is installed (e.g. to catch monad regressions immediately
while co-developing both repos), reintroduce the `init`/`std`/`runtime`
symlinks at the forge root and add explicit `[dependencies.init]` /
`[dependencies.std]` path entries back to each mote — that setup still works,
it's just not the default this repo uses.

### Map class workaround (Gap 1)

The `Map` class instance methods (`Map.insert`, `Map.get`, `Map.empty`) are
broken — pre-existing dictionary emission bug in `std/map.mo`. Until the fix
lands, Forge uses:
- `List (Pair String Any)` association lists for component lookups (simple, no
  class dependency)
- Standalone `HashMap.*`/`BTreeMap.*` functions if hash-based lookup is needed

## Workspace structure

```
forge/
├── mote.toml                    # [workspace] members = ["motes/*"]
├── devenv.nix                    # existing
└── motes/
    ├── forge-core/               # ECS, commands, query, world
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo            # re-exports
    │       ├── ecs.mo             # Entity, Archetype, ComponentStorage, World
    │       ├── commands.mo        # Command, Commands, CommandBuffer, flush
    │       ├── query.mo           # Query iteration, Changed filter
    │       └── tests/
    │           ├── ecs_tests.mo
    │           ├── commands_tests.mo
    │           └── query_tests.mo
    ├── forge-math/               # Vec2/3/4, Quat, Mat3/4, intersection
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── vec.mo
    │       ├── quat.mo
    │       ├── mat.mo
    │       ├── intersect.mo
    │       └── tests/
    │           └── math_tests.mo
    ├── forge-schedule/           # Schedule stages, system registration
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── schedule.mo
    │       ├── system.mo
    │       └── tests/
    │           └── schedule_tests.mo
    ├── forge-scene/              # Transform hierarchy, spawn templates
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── scene.mo
    │       └── tests/
    │           └── scene_tests.mo
    ├── forge-reactive/           # Signal, EventStream, dependency graph
    │   ├── mote.toml
    │   └── src/
    │       ├── lib.mo
    │       ├── reactive.mo
    │       ├── event.mo
    │       └── tests/
    │           └── reactive_tests.mo
    └── forge-app/                # App builder, plugin system, main loop
        ├── mote.toml
        └── src/
            ├── lib.mo
            ├── app.mo
            ├── plugin.mo
            └── tests/
                └── app_tests.mo
```

Each mote depends on `forge-core` (and transitively its deps) via path:
```toml
[dependencies.forge-core]
path = "../forge-core"
```
No `init`/`std`/`runtime` deps needed anywhere — the installed toolchain
supplies those (see "Workspace setup" above).

### Source file preamble

No `open init` is needed — resolved ambiently from the installed toolchain.
Source files can start directly with declarations. If a mote needs `std`
types (List, HashMap, etc.), use `use std::map {}` / `use std::list {List}`
etc.

## Implementation phases

### Phase 1: Workspace skeleton + forge-core ECS (P0)

**Mote:** `motes/forge-core/`

1. Create workspace `mote.toml` at forge root. **Done.**
2. Create `motes/forge-core/mote.toml` (no `init`/`std`/`runtime` deps needed
   — installed toolchain). **Done.**
3. Create `src/lib.mo` re-export hub. **Done** (re-exports `Entity`,
   `entity_id` from the probe; grows as `commands.mo`/`query.mo` land).
4. Implement `src/ecs.mo`:
   - `Entity { entity (id : U64, generation : U64) }` — **Done** (probe, with a
     passing `test_entity`)
   - `Archetype` — struct with `component_types : List String`, `columns : List (Pair String (List Any))`, `entities : List Entity`, `entity_index : List (Pair U64 I64)` (assoc list — Gap 1 workaround)
   - `ComponentStorage` — struct with `archetypes : List Archetype`, `entity_location : List (Pair U64 (Pair I64 I64))`, `free_ids : List U64`, `next_id : U64`
   - `World` — struct (NOT linear — Gap 2 workaround; runtime discipline: functions take and return `World`) with `storage : ComponentStorage`
   - `spawn (world : World) (components : List (Pair String Any)) : (World, Entity)` — allocate entity ID, find-or-create matching archetype, insert row
   - `despawn (world : World) (entity : Entity) : World` — mark dead, increment generation, push ID to free list
   - `insert_component (world : World) (entity : Entity) (key : String) (value : Any) : World` — archetype migration
   - `remove_component (world : World) (entity : Entity) (key : String) : World` — archetype migration
   - Archetype migration: find-or-create archetype matching new component set, move entity row, remove from old archetype
   - Entity generation: despawn increments generation, ID recycled after flush
5. Implement `src/commands.mo`:
   - `Command` type: `spawn (components : List (Pair String Any))`, `despawn (entity : Entity)`, `insert (entity : Entity) (key : String) (value : Any)`, `remove (entity : Entity) (key : String)`
   - `CommandBuffer` — struct with `commands : List Command`
   - `Commands` — handle wrapping a `CommandBuffer`
   - `flush (world : World) (buffer : CommandBuffer) : World` — applies all commands in order
6. Tests (`src/tests/ecs_tests.mo`):
   - spawn entity with components, verify archetype grouping
   - despawn, verify generation bump + ID recycling
   - insert/remove component, verify archetype migration
   - all tests use `U64`/`I64`/`String`/`Bool` only

**Acceptance:** `monad test -w` passes from forge root; `monad check -w` clean.

### Phase 2: forge-core Query + Change detection (P1)

**Mote:** `motes/forge-core/` (continued)

1. Implement `src/query.mo`:
   - `Query` — struct holding `reads : List String`, `writes : List String`, compiled against `World` to produce an iterator
   - `query_iter (world : World) (reads : List String) (writes : List String) : List (Pair Entity (List (Pair String Any)))` — collect matching entities (assoc list of component key -> value per entity)
   - `Changed` — per-entity, per-component generation counter in `ComponentStorage`; `changed_since (entity : Entity) (key : String) (last_seen : U64) : Bool`
   - `ChangedFilter` — struct with `key : String`, `last_seen : U64`
2. Tests (`src/tests/query_tests.mo`):
   - query entities by component set, verify results
   - change detection: modify a component, verify `Changed` filter fires; skip unmodified
   - command flush ordering: spawn in system A, visible in system B after flush

### Phase 3: forge-math (P3)

**Mote:** `motes/forge-math/`

1. `src/vec.mo`: `Vec2`, `Vec3`, `Vec4` as structs; `vec3_add`, `vec3_sub`, `vec3_scale`, `dot`, `cross`, `normalize`, `length`
2. `src/quat.mo`: `Quat`, `quat_from_axis_angle`, `quat_mul`, `quat_rotate`, `slerp`
3. `src/mat.mo`: `Mat3`, `Mat4`, `mat4_identity`, `mat4_translate`, `mat4_rotate`, `mat4_scale`, `mat4_perspective`, `mat4_orthographic`, `mat4_look_at`, `mat4_mul`
4. `src/intersect.mo`: `Ray`, `Plane`, `AABB`, `Sphere`, `ray_intersects_aabb`, `aabb_intersects_aabb`, `sphere_intersects_sphere`
5. Tests: F64 known-answer tests via `monad test` (F64 natives now wired); use `F64.beq` for assertions.
6. Field access `.x`/`.y`/`.z`/`.w` now works directly (Gap 3 fixed) — use it
   for reads in this math-heavy mote instead of `match v { mk x y z => x }`.

### Phase 4: forge-schedule (P2)

**Mote:** `motes/forge-schedule/` (depends on `forge-core`)

1. `ScheduleState` — enum type: `start_s`, `pre_init_s`, `init_s`, `first_s`, `pre_update_s`, `state_transition_s`, `fixed_update_s`, `update_s`, `post_update_s`, `last_s`, `render_s`, `cleanup_s`
2. `System` — struct with `name : String`, `stage : ScheduleState`, `run : World -> World` (function value)
3. `Schedule` — struct with `systems : List System`, ordered by stage
4. `add_system`, `add_system_to`, `flush` (command flush between stages)
5. `run_schedule (world : World) (schedule : Schedule) : World` — execute systems in stage order, flush commands between stages
6. Fixed timestep: `Time` resource with `fixed_accumulator`; `fixed_update_s` loops while `accumulator >= fixed_delta`
7. Parallel execution: deferred (no real parallelism in monad yet); model as sequential batches with dependency graph metadata

### Phase 5: forge-scene (P4)

**Mote:** `motes/forge-scene/` (depends on `forge-core`, `forge-math`)

1. `Transform` struct (translation Vec3, rotation Quat, scale Vec3)
2. `Parent`/`Children` components
3. `GlobalTransform` component (computed Mat4)
4. Transform propagation system: top-down, dirty-flag
5. Spawn templates: `SpawnTemplate := Commands -> World`

### Phase 6: forge-reactive (P8)

**Mote:** `motes/forge-reactive/` (depends on `forge-core`)

1. `Signal` struct: value + changed flag + dependency list
2. `signal_map`, `signal_zip`, `signal_fold`
3. `EventStream` struct: buffer + max_per_frame
4. `EventWriter`/`EventReader`
5. Frame-budgeted processing

### Phase 7: forge-app (P14)

**Mote:** `motes/forge-app/` (depends on all)

1. `App` builder, `Plugin` type
2. `DefaultPlugins` list
3. `App.run` main loop (cold -> warm -> command flush -> hot -> present)
4. Minimal demo: single-system app that increments a counter resource

## What is deferred from the original plan

- **Rendering (P7)**: requires GPU compute (`computational` mote doesn't exist yet). Deferred.
- **Physics (P11)**: GJK/EPA with F64 — deferred (native backend needed for full physics; F64 ops work, but solver complexity is high).
- **Audio (P10)**: native audio backend — deferred.
- **Networking (P12)**: UDP transport + rollback — deferred.
- **UI (P9)**: retained-mode tree + flexbox — deferred (large, depends on rendering).
- **Input/Window (P6)**: native OS bindings — deferred.
- **Editor (P13)**: depends on UI — deferred.
- **Linear type enforcement**: World/Entity/Asset are plain structs; ownership discipline is by convention (functions take and return `World`). No compile-time linear enforcement until Gap 2 is fixed.

## TDD approach

Each phase: write failing `#[test]` defs first, implement until `monad test`
passes. Run from forge root:
```bash
monad test -w                          # all motes
monad test motes/forge-core/src/tests/  # single mote
monad check motes/forge-math/           # typecheck (F64 tests also run via `monad test`)
```

## Tasks

- [x] Phase 1a: workspace skeleton — 6-mote layout, `forge-core`'s `Entity` probe, all motes wired with `path` deps, `monad test -w`/`check -w` clean
- [ ] Phase 1b: forge-core ECS (spawn/despawn/insert/remove, archetype migration, generation recycling, command buffer + flush)
- [ ] Phase 2: forge-core query iteration + change detection
- [ ] Phase 3: forge-math (Vec/Quat/Mat/intersection) — F64 known-answer tests
- [ ] Phase 4: forge-schedule (stages, system registration, fixed timestep, command flush)
- [ ] Phase 5: forge-scene (transform hierarchy, propagation, spawn templates)
- [ ] Phase 6: forge-reactive (Signal, EventStream, dependency graph)
- [ ] Phase 7: forge-app (builder, plugin, main loop, minimal demo)
