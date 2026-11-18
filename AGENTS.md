# AGENTS.md

Forge is a game engine written in Monad (`.mo`), set up as a workspace of
motes in `motes/forge-*`, plus an example game in `games/mo-venture`. Read
`README.md` for usage and `PLAN.md` for design, status and known toolchain
gaps (G1–G12). Read the parts you need;
don't read either file end to end.

## Commands

Run everything from the repo root, inside `devenv shell` (or prefix
`devenv shell --`).

| Goal | Command | Time |
|---|---|---|
| typecheck all | `monad check -w` | ~5–10 min, run in background |
| test all (the real gate) | `monad test -w` | ~10+ min, run in background |
| one mote, fast | copy the lock in first (below) | ~2–3 min |
| wasm build + Node smoke | `scripts/web-smoke.sh [demo\|mo-venture]` | ~3 min per app |
| serve the demo / the game | `scripts/web-serve.sh [mo-venture]` (port 8080) | |
| update the monad pin | `monad update` | seconds |

- **`monad check` passing is not enough.** Some failures only show up in
  `monad test`, at lowering or at run time. Before calling work done, run
  `test`.
- **Member-scoped commands** (`monad test motes/forge-app`) fail with
  "web_wasm not in mote.lock" (G2). For a quick single-mote loop, copy the
  root lock into the mote for the duration of the command, then remove it,
  and never commit it:
  `for d in motes/forge-app motes/forge-webgl games/mo-venture; do cp mote.lock $d/mote.lock; done`,
  run `monad test motes/forge-app` (or `games/mo-venture`), then
  `rm -f motes/forge-app/mote.lock motes/forge-webgl/mote.lock games/mo-venture/mote.lock`.
  Motes that don't reach `web_wasm` (forge-core, forge-math, forge-collide,
  ...) test without the copies.
- `games/mo-venture` compiles slowly (minutes per file); run its tests in
  the background.
- Don't put `rm` inside `bash -c '...'`: the harness blocks the whole
  command. Run removals as their own command with explicit paths.
- When polling a background job, don't `pkill -f 'monad ...'` or `pgrep`
  a pattern that matches your own shell's command line.

## Keep the monad pin current

`mote.toml` tracks monad's `main` for `web_wasm`; `mote.lock` pins the
commit. Run `monad update` when starting work. If `git_commit` in
`mote.lock` changes, check that commit out in `../monad`, re-run
`monad test -w` and `scripts/web-smoke.sh`, and commit the lock.

## Monad idioms that save a failed compile

- **Affine by default.** A binder of a non-`Copy` type can be used once.
  - For persistent structs, write an identity instance:
    `instance Copy T { def copy (x : T) : Pair T T := Pair.pair x x }`.
  - `#[derive Copy Clone]` needs `use std::derive {}`; enums need the
    derive macros by name (`use std::derive {derive_copy, derive_clone}`).
  - A `<-`-bound value stays affine even when annotated (G3). Pass it to a
    helper with a typed parameter.
  - A value bound by a match arm (`Option.some x`) is reused after
    rebinding it: `let x : T := x0`.
  - `List` is not `Copy`: write helpers that make one pass over it.
- Write `==` and `+`, not `I64.beq`/`String.beq`/`I64.add`. Negate with
  `Bool.not (e)`; there is no prefix `!` (G10).
- `List.get idx list` takes the index first.
- No field access on a call result (`(f x).field` is "unknown variable
  'field'", G11). Bind it with `let`, or use a getter.
- `pub use` re-exports work within a mote but not across motes (G12): a
  game must depend on, and `use`, the mote that declares a type
  (`use forge_math {Vec3}`), even if `forge_app` re-exports it.
- An unresolved `use` is only a warning (G4). Read `check` output for
  "unresolved module". Don't import types from transitive dependencies
  such as `web_event` (G9).
- `StateT` over `ResultT` miscompiles `pure` (G1). Use `FallibleWorld`.
- A system is `WorldM Id Unit` (pure). World resources (`Time`, `Input`)
  are singleton entities read with `world_time` / `world_input`.

## Layout rules

- `forge-webgl`, `forge_app::web` and `motes/forge-app/src/main.mo` are
  **web-only**. `lib.mo` must not re-export `web.mo`, so the native test
  binary never links WebGL externs. Put logic in native modules and test
  it there; the web side gets only thin glue.
- Backend-neutral rendering decisions go in `forge-render`
  (`frame_plan`). `forge-webgl` only executes a `FramePlan`.
- A game lives in `games/<name>`: game logic in native modules with tests,
  a web bin `src/main.mo`. It builds its `App` with `forge_app` and names
  engine types from their own motes (G12).
- Collision is `forge-collide` (shapes, GJK/EPA, broad phase, queries,
  events, `move_and_slide`). Its tests are the fast loop (~30 s).

## Shell

The shell is zsh. In `git show "$R:path"`, `$R:w` gets expanded as a
modifier, so quote it as `"${R}:path"`. Unquoted globs such as
`--include=*.mo` fail with "no matches found", so quote them too.

## Records

- Monad and mote gaps go in `PLAN.md`'s gap table and in
  `~/src/monad-plans/implementations/2026-11-17-forge-webgl-consumer-gaps.md`,
  each with a repro you have verified.
- Commit only when asked. History is linear on `main`.
