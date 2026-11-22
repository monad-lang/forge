# Forge

A game engine written in [Monad](https://github.com/monad-lang/monad), built
as a workspace of motes (`motes/forge-*`): an affine-safe ECS, a math
library, schedules, a scene graph, reactive signals, collision detection
with a character controller, a backend-neutral renderer, and a WebGL
backend. `games/mo-venture` is an example game built on it. See
[PLAN.md](PLAN.md) for the design and its status.

## Prerequisites

- [devenv](https://devenv.sh). The dev shell provides clang, lld and a
  static Boehm GC, and sets `MONAD_WEB_CC` for wasm builds. Run everything
  through `devenv shell -- <command>` or inside `devenv shell`.
- The `monad` toolchain on `PATH`.
- For the browser demo:
  - a **monad checkout** next to this repo (`../monad`, or point
    `MONAD_SRC` at it) that has the `web_wasm` commit pinned in
    `mote.lock` (`git_commit`). The web host JavaScript is not shipped with the
    toolchain, so the build copies it from that checkout. The checkout's
    web files must match the pin (check out that rev there if the build
    says they differ);
  - `python3`, to serve the page. Any static file server works;
  - a browser with WebGL 1 or 2.

## Tests

```sh
devenv shell -- monad check -w     # typecheck every mote
devenv shell -- monad test -w      # native tests for every mote
```

Run these from the repo root. Member-scoped commands such as
`monad test motes/forge-app` fail to find the git dependency's lock (see
PLAN.md, gap G2).

## Keeping the monad pin current

`mote.toml` tracks the monad repo's `main` (the `web_wasm` git
dependency), and `mote.lock` records the exact commit. Keep it current:

```sh
devenv shell -- monad update     # move mote.lock to upstream main's head
```

If the commit changed, check it out in the monad checkout
(`git_commit` in `mote.lock`), run `monad test -w` and
`scripts/web-smoke.sh`, and commit `mote.lock`.

## Play Mo Venture

```sh
devenv shell -- scripts/web-serve.sh mo-venture
```

Then open <http://localhost:8080>. The web build needs a nightly with
monad's web collector (`nightly-2026-11-19-b0fe09df` or later, PLAN.md gap
G13). An older `monad` links the old runtime and fails with "undefined
symbol: monad_export_enter"; run `monadup default`.

Mo, a small blue explorer with an antenna, plays four levels:

1. **Skyway**: floating platforms, stairs, a narrow bridge, a climb, a gap
   that needs the air dash and a high ledge.
2. **Cloud Steps**: ledges too tall and gaps too wide for one jump. Jump
   again in the air, and once, jump again and dash.
3. **Drift Docks**: a shuttle, an elevator and a ferry over the void. Wait
   for a platform, ride it, step off.
4. **Sun Spire**: a climb that needs all of it.

Mo is either Xiaozhu (小猪), a pink piggy, or Xiaomao (小猫), a ginger
kitty; press `C` to switch at any time (the run carries on). Each level has
sparks to collect, two checkpoints and a goal beacon. A warm
sun lights the scene and casts shadows (a shadow map; on WebGL1 without
`WEBGL_depth_texture` the scene is lit without them).

| Input | Effect |
|---|---|
| `W` `A` `S` `D` or the arrow keys | run, relative to the camera |
| `Space` | jump (hold for a higher jump); `Space` again in the air jumps once more |
| `Shift` | on the ground (held): sprint; in the air (pressed): dash, once per jump |
| right-drag, `Q` / `E`, `R` / `F` | turn the camera |
| mouse wheel | zoom |
| `P` | autopilot: Mo plays the level by itself |
| `Enter` | after the goal: the next level |
| `1` to `4` | play that level |
| `Backspace` | restart the level |
| `C` | switch Mo between Xiaozhu the piggy and Xiaomao the kitty |

On a touch screen the page shows on-screen controls instead of the key
list: a stick on the left to run, `JUMP` and `DASH` on the right (they act
like `Space` and `Shift`, so tap `JUMP` again in the air for the second
jump), ◀ ▶ to turn the camera, and small buttons for the autopilot (`P`),
restart (↺), the next level (▶▶) and the hero (🐱 / 🐷, like `C`). They are page glue in
`games/mo-venture/web/index.html` that sends the same key events.

Falling off sends Mo back to the last checkpoint. The HUD shows the level,
sparks, time and falls.

The game is in `games/mo-venture`: `src/level.mo` and `src/levels.mo` are
the levels as data, `src/mo.mo` Mo's controller, `src/rules.mo` the rules
and HUD, `src/game.mo` the app and the campaign, and `src/bot.mo` the
autopilot. Its native tests play every level with the autopilot through
forge's frame loop.

## Run the demo in a browser

```sh
devenv shell -- scripts/web-serve.sh
```

Then open <http://localhost:8080>.

The script builds into `target/web/demo/` (`scripts/web-build.sh`) and serves
that directory on localhost. Set `PORT=9000` to change the port, or
`NO_BUILD=1` to serve the last build again without rebuilding. Open the page
through the server: ES modules and WebAssembly do not load from `file://`.

The demo is a spinning red cube with a teal cylinder orbiting it and a gold
cube spinning and bobbing on top (a forge-animate clip), above a checkered
floor:

| Input | Effect |
|---|---|
| `W` `A` `S` `D` or the arrow keys | slide the cube hierarchy across the floor, relative to the camera |
| `Shift` (held) | move faster |
| right-drag or middle-drag | orbit the camera |
| `Q` / `E` | orbit left / right |
| `R` / `F` | orbit up / down |
| mouse wheel | zoom |
| click | pick the collider under the cursor (shown bottom left) |

If WebGL is unavailable, the page shows the error in a red box at the top
left.

### What the build produces

| File in `target/web/<app>/` | From |
|---|---|
| `app.wasm` | the app's web bin (`forge-app-web` or `mo-venture-web`), built for `wasm32-unknown-unknown` |
| `web.js` | generated by the monad checkout's `scripts/gen-web-js.sh` |
| `web_runtime.js`, `float_format.js` | the monad checkout's `wasm/web/`, at the pinned rev |
| `index.html` (and images) | `web/` (demo) or `games/mo-venture/web/` |

### Without a browser

```sh
devenv shell -- scripts/web-smoke.sh
```

This runs the same builds and then drives both apps in Node against monad's
recording stub DOM and stub WebGL, in WebGL 2, WebGL 1 and no-WebGL modes.
For the demo it checks setup, draws per frame, texture upload, picking,
keyboard movement and context-loss recovery. For Mo Venture it checks
running and jumping by key and the autopilot climbing the stairs. Both then
run long (6000 demo frames, 900 more Mo Venture frames) and fail if the wasm
memory passes a ceiling (`HEAP_CEILING_MIB`, 128 and 256; `LONG_FRAMES`
sets the length). `scripts/web-smoke.sh mo-venture` runs one app.

## Writing a web game

Copy the shape of `games/mo-venture`: a mote with `targets = ["web"]`, the
game logic in native modules with tests, and a web bin `src/main.mo`. Its
dependencies are `forge_app` plus the engine motes it names types from
(`pub use` re-exports do not reach across motes yet, PLAN.md gap G12). For
the smallest example, see `motes/forge-app/src/main.mo`:

1. Build an `App` with `forge_app`: systems, assets, initial world.
2. In systems, read input with `world_input world`, using `input_key_held`,
   `input_key_pressed`, `input_axis`, `input_pointer_x`, `input_delta_x`,
   `input_button_pressed`, `input_wheel_delta` and so on. Keys use physical
   `KeyboardEvent.code` names (`"KeyW"`, `"ArrowLeft"`, `"Space"`). Read the
   frame time with `time_delta (world_time world)`.
   For an orbit camera, call `app_add_orbit_camera app (orbit_new target yaw
   pitch distance fovy)`. To steer relative to the view, use
   `orbit_forward` / `orbit_right` of `world_orbit_opt world`.
3. Export the three thunks the web loader calls, delegating to
   `forge_app::web`:

   ```
   #[export "c"]
   def oak_mount : IO Unit := web_mount my_app my_rig   // e.g. orbit_rig my_orbit

   #[export "c"]
   def oak_dispatch_event (handler : I64) : IO Unit := web_dispatch handler

   #[export "c"]
   def oak_tick : IO Unit := web_tick
   ```
