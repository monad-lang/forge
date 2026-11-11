// forge-render: the headless/soft backend. Phase 8, see ../../../PLAN.md.
//
// `soft` is what makes the render pipeline testable with no GPU: it records
// every submitted command in a `Ref (List RenderCommand)` so a test can assert
// what a frame produced. The type and its operations live in `backend.mo`
// (they are part of the `Renderer` enum); this module is the thin, named entry
// point so callers say `soft::new` rather than reaching into `backend`.

use std::ref {Ref, Ref.get}
use std::list {}
use lib::command {RenderCommand}
use lib::backend {
    Renderer, soft_renderer, renderer_recorded, renderer_is_recording, headless_renderer
}

/// A recording backend of the given surface size.
pub def new (w : I64) (h : I64) : IO Renderer := soft_renderer w h

/// The commands recorded so far.
pub def recorded (r : Renderer) : IO (List RenderCommand) := renderer_recorded r

/// How many commands have been recorded.
pub def recorded_count (r : Renderer) : IO I64 := do {
    let cmds <- renderer_recorded r;
    return (List.length cmds)
}

/// Does this backend record?
pub def is_soft (r : Renderer) : Bool := renderer_is_recording r

/// A backend that records nothing.
pub def none : Renderer := headless_renderer

#[test]
def test_soft_module_records : IO Bool := do {
    let r <- new 640 480;
    let n <- recorded_count r;
    return (I64.beq n 0 && is_soft r)
}

#[test]
def test_soft_and_backend_agree : IO Bool := do {
    let r <- new 640 480;
    let a <- recorded r;
    let b <- recorded_count r;
    return (I64.beq (List.length a) b)
}
