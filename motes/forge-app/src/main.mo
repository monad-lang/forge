// forge-app on the web: the wasm-only entry point.
//
// This is the ONLY file in the mote that names a `web_wasm` extern, and it is
// a declared `[[bin]]` of a `targets = ["web"]` mote. That is what keeps the
// native path clean: `monad test` filters a web-only bin out of its sweep
// (`Mote.web_only_bin_file`), so the lib and its tests still run natively.
// `monad check` does NOT filter it -- a web bin type-checks fine on the
// native target, because extern availability is a CODEGEN gate
// (`validate_native_target_availability`), not a checker one.
//
// This is Phase 9a of ../../../PLAN.md: forge's frame is
// propagate -> run_schedule_pure -> extract, and this file is the WebGL
// consumer of the `List RenderCommand` it produces.

use init::io {IO}
use init::copy {Copy}
use web_wasm::types {Node}
use web_wasm::dom {Dom.append, Dom.create, Dom.root, Dom.set_attr}
use web_wasm::canvas {Canvas.fit}
use web_wasm::gl {
    GlContext, GlProgram, GlUniform, GlOptions, GlOptions.default,
    GlPrimitive, GlClear, GlCap, Gl.context, Gl.drawing_buffer_size,
    Gl.program, Gl.use_program, Gl.uniform_location, Gl.uniform1f,
    Gl.viewport, Gl.clear_color, Gl.clear, Gl.enable, Gl.draw_arrays,
}
use forge_render {Color, color_r, color_g, color_b, color_a, color_clear}

// ── Affinity ────────────────────────────────────────────────────────
//
// `Node` is an opaque handle: a JS-side node id, never constructed, matched
// or compared here. `web_wasm` declares no `Copy Node`, and monad's own
// workspace runs the affine rule as a WARNING (`[affine] mode = "warn"`), so
// its fixtures pass a node to several calls and only get warned. This
// workspace runs the rule as an ERROR, and a canvas legitimately has to be
// sized, attributed and then handed to `getContext`.
//
// The instance below is the identity form `forge_core`'s `World` and
// `forge_render`'s `Renderer` already use, and for the same reason: the
// handle is immutable and the duplicate SHARES it, it never mutates. A node
// id is a plain number on the host's side, so two copies naming one node is
// exactly what the DOM wants.
instance Copy Node {
    def copy (n : Node) : Pair Node Node := Pair.pair n n
}

/// The scene: a context, a linked program and the uniform it drives.
///
/// `GlContext`, `GlProgram` and `GlUniform` all carry `Copy` instances in
/// `web_wasm`, so this record is safe to read as often as a frame needs.
struct WebGlScene {
    ctx : GlContext,
    program : GlProgram,
    time : GlUniform
}

/// A flat-colour vertex shader. A full-viewport triangle from `gl_VertexID`
/// would need WebGL2, so the three corners are spelled out.
def vertex_source : String :=
    "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"

/// The fragment shader takes the frame's time, so the drawn colour is a
/// function of the loop rather than a constant.
def fragment_source : String :=
    "precision mediump float; uniform float u_time; void main() { gl_FragColor = vec4(u_time, 0.0, 0.0, 1.0); }"

/// Assemble the scene record. A named def rather than an inline literal: a
/// struct literal nested inside `Result.ok` inside a `match` arm inside a `do`
/// block never reaches the checker with an expected type, so its fields infer
/// as bare type variables. The symptom is NOT "missing instance" but
/// "`ctx` : A is used 3 times but is affine" -- the fields look like fresh
/// type parameters, so the affine gate fires before instance lookup runs.
def scene_new (c : GlContext) (p : GlProgram) (u : GlUniform) : WebGlScene :=
    { ctx := c, program := p, time := u }

/// Resolve `u_time` and finish the scene. Its own def for the reason above.
def uniform_of (c : GlContext) (p : GlProgram) : IO (Result String WebGlScene) := do {
    let loc <- Gl.uniform_location c p "u_time";
    match loc {
        Option.none => IO.pure (Result.err "no u_time uniform"),
        Option.some time => IO.pure (Result.ok (scene_new c p time)),
    }
}

/// Compile and link the program, then resolve its uniform.
def link_of (c : GlContext) : IO (Result String WebGlScene) := do {
    let built <- Gl.program c vertex_source fragment_source;
    match built {
        Result.err e => IO.pure (Result.err e),
        Result.ok program => uniform_of c program,
    }
}

/// Ask `canvas` for a context and link the program. `Result` carries the
/// driver's info log when a shader fails, which is the only way a GL failure
/// is legible from here.
pub def webgl_setup (canvas : Node) : IO (Result String WebGlScene) := do {
    let found <- Gl.context canvas GlOptions.default;
    match found {
        Option.none => IO.pure (Result.err "no webgl context"),
        Option.some ctx => link_of ctx,
    }
}

/// Size the viewport to the context's drawing buffer. Split out because a
/// `match` on a `Pair` is a statement here, and the shape the parser accepts
/// is a one-arm match in a def of its own (the same helper `web_wasm`'s own
/// WebGL fixture uses).
def viewport_to (ctx : GlContext) (size : Pair I64 I64) : IO Unit :=
    match size { Pair.pair w h => Gl.viewport ctx 0 0 w h }

/// One frame of GL work: size the viewport, clear to `clear`, then draw the
/// triangle with the frame's time.
///
/// The viewport is read from the CONTEXT rather than from a stored size, so
/// a resize needs no bookkeeping here: `Canvas.fit` on the canvas is enough.
pub def webgl_draw (scene : WebGlScene) (clear : Color) (t : F64) : IO Unit :=
    match scene {
        { ctx, program, time } => do {
            let size <- Gl.drawing_buffer_size ctx;
            let _ <- viewport_to ctx size;
            let _ <- Gl.clear_color ctx (color_r clear) (color_g clear) (color_b clear) (color_a clear);
            let mask : GlClear := { color := true, depth := true, stencil := false };
            let _ <- Gl.clear ctx mask;
            let _ <- Gl.enable ctx GlCap.depth_test;
            let _ <- Gl.use_program ctx program;
            let _ <- Gl.uniform1f ctx time t;
            Gl.draw_arrays ctx GlPrimitive.triangles 0 3
        },
    }

/// The browser entry point: mount a `<canvas>`, fit its drawing buffer, bring
/// up WebGL, then draw one frame.
///
/// The canvas is created here rather than read with `Dom.query`, so the
/// program does not depend on the host page having one. A frame loop
/// (rAF -> `app_frame` -> `webgl_draw`) is Phase 9a step 6, which needs the
/// animation-frame subscription and a `dt` source; this proves the boundary
/// compiles and runs.
def main : IO Unit := do {
    let root <- Dom.root;
    let canvas <- Dom.create "canvas";
    let _ <- Dom.set_attr canvas "id" "forge";
    let _ <- Dom.append root canvas;
    // A zero-sized canvas has a 0x0 drawing buffer, and a 0-height viewport
    // draws nothing -- `Canvas.fit` is what makes the buffer real.
    let _ <- Canvas.fit canvas;
    let scene <- webgl_setup canvas;
    match scene {
        Result.err _ => IO.pure unit,
        Result.ok s => webgl_draw s color_clear 0.0,
    }
}
