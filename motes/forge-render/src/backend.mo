// forge-render: the `Renderer` interface. Phase 8, see ../../../PLAN.md.
//
// `Renderer` is an ENUM, not a record of closures: a struct cannot hold a
// `-> IO Unit` field ("term_to_expr_value: unsupported term shape"), and an
// enum also makes "which backend is this" exhaustive and matchable. Each
// variant carries the state that backend needs.
//
// `Copy` is hand-written (identity): a `Renderer` is a handle to shared backend
// state (`Ref`s), and duplicating the handle shares that state, which is what
// a renderer wants.

use std::ref {Ref, Ref.new, Ref.get, Ref.set, Ref.update}
use std::derive {derive_debug}
use std::list {}
use init::copy {Copy}
use lib::command {RenderCommand, clear, color_black}

/// A drawing backend. `soft` records commands (tests/CI); `headless` drops
/// them. A GPU/WebGL backend becomes a further variant without the core
/// changing.
#[derive Debug]
pub type Renderer {
    soft (recorded : Ref (List RenderCommand), width : Ref I64, height : Ref I64),
    headless
}

pub instance Copy Renderer {
    def copy (r : Renderer) : Pair Renderer Renderer := Pair.pair r r
}

/// A backend that discards everything.
pub def headless_renderer : Renderer := headless

/// Build a recording backend.
pub def soft_renderer (w : I64) (h : I64) : IO Renderer := do {
    let recorded <- Ref.new ([] : List RenderCommand);
    let rw <- Ref.new w;
    let rh <- Ref.new h;
    return (soft recorded rw rh)
}

/// Hand a frame's commands to the backend.
pub def renderer_submit (r : Renderer) (cmds : List RenderCommand) : IO Unit :=
    match r {
        soft recorded _ _ => do {
            let _ <- Ref.update recorded (fn (xs : List RenderCommand) => List.append xs cmds);
            return unit
        },
        headless => Monad.pure unit
    }

/// Present the frame.
pub def renderer_present (r : Renderer) : IO Unit :=
    match r {
        soft _ _ _ => Monad.pure unit,
        headless => Monad.pure unit
    }

/// Tell the backend the surface size changed.
pub def renderer_resize (r : Renderer) (w : I64) (h : I64) : IO Unit :=
    match r {
        soft _ rw rh => do {
            Ref.set rw w;
            Ref.set rh h;
            return unit
        },
        headless => Monad.pure unit
    }

/// Release backend resources.
pub def renderer_shutdown (r : Renderer) : IO Unit :=
    match r {
        soft recorded _ _ => do {
            Ref.set recorded ([] : List RenderCommand);
            return unit
        },
        headless => Monad.pure unit
    }

/// Whether the renderer actually stores frames.
pub def renderer_is_recording (r : Renderer) : Bool :=
    match r {
        soft _ _ _ => true,
        headless => false
    }

/// The commands a recording backend has stored, oldest first (empty for a
/// non-recording backend).
pub def renderer_recorded (r : Renderer) : IO (List RenderCommand) :=
    match r {
        soft recorded _ _ => Ref.get recorded,
        headless => Monad.pure ([] : List RenderCommand)
    }

/// The current surface size.
pub def renderer_size (r : Renderer) : IO (Pair I64 I64) :=
    match r {
        soft _ rw rh => do {
            let w <- Ref.get rw;
            let h <- Ref.get rh;
            return (Pair.pair w h)
        },
        headless => Monad.pure (Pair.pair 0 0)
    }

/// Submit a whole frame, then present it.
pub def renderer_draw_frame (r : Renderer) (cmds : List RenderCommand) : IO Unit := do {
    renderer_submit r cmds;
    renderer_present r
}

#[test]
def test_headless_is_not_recording : Bool :=
    Bool.not (renderer_is_recording headless_renderer)

#[test]
def test_headless_has_a_zero_size : IO Bool := do {
    let wh <- renderer_size headless_renderer;
    match wh {
        Pair.pair w _ => return (I64.beq w 0)
    }
}

#[test]
def test_soft_is_recording : IO Bool := do {
    let r <- soft_renderer 800 600;
    return (renderer_is_recording r)
}

#[test]
def test_soft_submit_records : IO Bool := do {
    let r <- soft_renderer 800 600;
    renderer_submit r [clear color_black];
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) 1)
}

#[test]
def test_soft_resize_stores_the_size : IO Bool := do {
    let r <- soft_renderer 800 600;
    renderer_resize r 1024 768;
    let wh <- renderer_size r;
    match wh {
        Pair.pair w h => return (I64.beq w 1024 && I64.beq h 768)
    }
}

#[test]
def test_soft_shutdown_clears_the_recording : IO Bool := do {
    let r <- soft_renderer 10 10;
    renderer_submit r [clear color_black];
    renderer_shutdown r;
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) 0)
}

#[test]
def test_draw_frame_submits : IO Bool := do {
    let r <- soft_renderer 10 10;
    renderer_draw_frame r [clear color_black];
    let recorded <- renderer_recorded r;
    return (I64.beq (List.length recorded) 1)
}
