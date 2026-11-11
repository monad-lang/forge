// forge-render: backend-agnostic render interface. Phase 8, see
// ../../../PLAN.md.
//
// `command` is the vocabulary (RenderCommand + Camera/MeshHandle/Color);
// `extract` turns a `World` into commands; `backend` is the `Renderer`
// interface; `soft` is the headless recording backend. Adding a GPU or WebGL
// backend means adding a `Renderer` variant, not touching any of the rest.

pub use lib::command {
    MeshHandle, mesh_handle, mesh_handle_id,
    MaterialHandle, material_handle, material_handle_id,
    Color, color, color_rgb, color_black, color_white, color_clear,
    color_r, color_g, color_b, color_a,
    Camera, camera_new, camera_view, camera_projection, camera_position,
    camera_view_projection,
    RenderCommand, clear, set_camera, draw_mesh, present_cmd_unit,
    command_kind, is_draw, count_draws
}

pub use lib::extract {
    MeshComponent, mesh_component, mesh_component_mesh, mesh_component_material,
    mesh_name, set_mesh, entity_mesh, DrawItem, drawables, draw_commands,
    extract, drawable_count
}

pub use lib::backend {
    Renderer, headless_renderer, soft_renderer,
    renderer_submit, renderer_present, renderer_resize, renderer_shutdown,
    renderer_is_recording, renderer_recorded, renderer_size, renderer_draw_frame
}
