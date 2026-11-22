// forge-render: backend-agnostic render interface. Phase 8, see
// ../../../PLAN.md.
//
// `command` is the vocabulary (RenderCommand + Camera/MeshHandle/Color);
// `extract` turns a `World` into commands; `backend` is the `Renderer`
// interface; `soft` is the headless recording backend.
//
// Phase 9a added the data a REAL backend needs, still with no backend type in
// sight: `mesh` (geometry), `material` (materials, textures, the `Assets`
// table), `plan` (`frame_plan`: commands + assets -> a resolved `FramePlan`)
// and `pick`. A drawing backend is an executor of a `FramePlan` (forge-webgl
// is the first); it makes no decisions of its own.

pub use lib::command {
    MeshHandle, mesh_handle, mesh_handle_id,
    MaterialHandle, material_handle, material_handle_id,
    Color, color, color_rgb, color_black, color_white, color_clear,
    color_r, color_g, color_b, color_a,
    Camera, camera_new, camera_view, camera_projection, camera_position,
    camera_view_projection,
    RenderCommand, clear, set_camera, set_light, draw_mesh, present_cmd_unit,
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

pub use lib::mesh {
    MeshData, mesh_data, mesh_stride, mesh_vertices, mesh_indices, mesh_vertex_count,
    mesh_index_count, mesh_triangle_count, mesh_is_valid, mesh_bounds,
    mesh_quad, mesh_box, mesh_cube, mesh_disc, mesh_cylinder, mesh_sphere
}

pub use lib::material {
    ShaderKind, shader_flat, shader_textured, shader_kind_code,
    TextureHandle, texture_handle, texture_handle_id, texture_none, texture_is_none,
    TextureFilter, filter_nearest, filter_linear, TextureWrap, wrap_repeat, wrap_clamp,
    TextureDesc, texture_desc, texture_from_url, texture_url, texture_filter,
    texture_wrap, texture_is_linear, texture_repeats,
    Material, material_flat, material_unlit, material_textured, material_default, material_shader,
    material_tint, material_texture, material_is_unlit,
    Assets, assets_empty, MeshAdded, MaterialAdded, TextureAdded,
    assets_add_mesh, assets_add_material, assets_add_texture,
    assets_mesh, assets_material, assets_texture, assets_mesh_ids, assets_texture_ids,
    assets_mesh_count, assets_material_count, assets_texture_count,
    assets_material_or_default
}

pub use lib::plan {
    DrawCall, draw_call_mesh, draw_call_shader, draw_call_tint, draw_call_texture,
    draw_call_model, draw_call_unlit,
    FramePlan, plan_empty, plan_clears, plan_clear_color, plan_view, plan_projection,
    plan_view_projection, plan_draws, plan_draw_count, plan_skipped, plan_presents,
    plan_light, plan_shadows, plan_light_view_projection, plan_casters,
    resolve_draw, frame_plan, camera_screen_ray
}

pub use lib::light {
    Light, light_sun, light_default, light_with_shadows, light_at, light_toward, light_color,
    light_intensity, light_ambient, light_shadows, light_focus, light_extent, light_depth,
    light_map_size, light_diffuse, light_texel, light_snapped_focus, light_view, light_projection,
    light_view_projection, light_name, world_light_opt, world_light, world_set_light
}

pub use lib::pick {
    Picked, picked_entity, picked_distance, ray_hits_placed_box, pick_entity
}
