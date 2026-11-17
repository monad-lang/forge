// forge-webgl: the WebGL backend. Phase 9a, see ../../../PLAN.md.
//
// A wasm-only executor of forge-render's `FramePlan`: it owns the GL
// objects (two programs, a buffer pair per mesh, a texture per texture id)
// and turns each resolved `DrawCall` into one `drawElements`. Everything
// about WHAT to draw is decided upstream, purely, in `frame_plan`.
//
// A game does not depend on this mote directly: `forge_app::web` re-exports
// this surface next to the frame driver.

pub use lib::renderer {
    WebGlRenderer, webgl_attach, webgl_create, webgl_submit,
    webgl_resize, webgl_rebuild, webgl_set_assets,
    webgl_canvas, webgl_version, webgl_is_lost, webgl_mesh_count, webgl_client_size,
    Size2, size_width, size_height, size_aspect
}

pub use lib::shaders {
    vertex_source, flat_fragment_source, textured_fragment_source,
    vertex_stride_bytes, uv_offset_bytes
}
