// forge-webgl: the WebGL executor of a `FramePlan`. Phase 9a, see
// ../../../PLAN.md.
//
// This backend makes NO decisions. forge-render's `frame_plan` has already
// resolved a frame -- clear colour, camera, and per draw a mesh that exists,
// a shader kind, a tint, a texture, a model matrix -- and `webgl_submit`
// issues the GL calls for exactly that, one `drawElements` per `DrawCall`.
// What it owns is GPU STATE: the two linked programs and, per asset id, the
// buffers and textures uploaded for it.
//
// Why a separate mote and not a `Renderer` enum arm: an arm would make
// forge-render import `web_wasm`, whose externs exist only on the browser
// target, and a reachable web-only extern is a compile error natively -- so
// forge-render's own tests would stop building.
//
// Shape notes that are not obvious from the code:
//
// - Every record here carries a hand-written identity `Copy`. They hold GL
//   handles (plain host-side ids) and `Ref`s, so a duplicate shares.
// - Records are built by NAMED constructor defs. A struct literal nested in
//   `Result.ok` in a `match` arm in a `do` block reaches the checker with no
//   expected type, its fields infer as bare type variables, and the affine
//   gate fires on them before any `Copy` instance is looked up.
// - A uniform or attribute a program does not use is optimised out by the
//   driver and has no location. That is normal (the flat program has no
//   `u_tex`), so a location is a `Slot` that may be empty, and setting an
//   empty slot is a no-op -- not an error.
// - Element indices are 32-bit (`Buf I32`, the only integer `Buf` kind the
//   GL boundary takes). WebGL2 has them; WebGL1 needs
//   `OES_element_index_uint`, and setup fails with a message without it.
// - Textures load asynchronously. A textured draw whose image is not ready
//   (or failed) is drawn with the flat program and its tint, so a frame is
//   never blocked on the network.
// - Context loss: `webgl_submit` draws nothing while the context is lost,
//   and on the first frame after it returns it relinks the programs and
//   re-uploads every asset (everything a context owned died with it).
// - Shadows: the first frame whose plan asks for them (`plan_shadows`)
//   creates the shadow map -- a depth texture of the light's `map_size`, a
//   framebuffer and a position-only program. If any of it is missing
//   (WebGL1 without `WEBGL_depth_texture`, an incomplete framebuffer) the
//   renderer remembers that and draws lit without shadows. Each shadowed
//   frame renders `plan_casters` depth-only into the map, then the main pass
//   samples it on texture unit 1. Frames without shadows issue no shadow
//   calls at all. A restored context tries again.

use std::ref {Ref, Ref.new, Ref.get, Ref.set, Ref.update}
use std::map {HashMap, Map}
use std::list {}
use init::copy {Copy}
use web_wasm::types {Node}
use web_wasm::dom {Dom.append, Dom.create, Dom.root, Dom.set_attr}
use web_wasm::canvas {Canvas.fit, Canvas.client_size}
use web_wasm::gl {
    GlContext, GlProgram, GlBuffer, GlTexture, GlUniform, GlImage, GlFramebuffer, GlAttachment,
    GlOptions, GlOptions.default, GlBufferTarget, GlUsage, GlAttribType, GlPrimitive,
    GlTextureTarget, GlFilter, GlWrap, GlClear, GlCap, GlBlendFactor, GlCompare,
    Gl.context, Gl.is_lost, Gl.version, Gl.drawing_buffer_size, Gl.has_uint_indices,
    Gl.program, Gl.use_program, Gl.attrib_location, Gl.uniform_location,
    Gl.uniform4f, Gl.uniform3f, Gl.uniform1f, Gl.uniform1i,
    Gl.create_buffer, Gl.bind_buffer, Gl.delete_buffer,
    Gl.vertex_attrib_pointer, Gl.enable_vertex_attrib,
    Gl.viewport, Gl.clear_color, Gl.clear, Gl.enable, Gl.blend_func, Gl.depth_func,
    Gl.draw_elements, Gl.disable, Gl.color_mask, Gl.polygon_offset,
    Gl.create_framebuffer, Gl.bind_framebuffer, Gl.bind_default_framebuffer, Gl.delete_framebuffer,
    Gl.framebuffer_texture, Gl.framebuffer_complete, Gl.tex_image_depth,
    Gl.create_texture, Gl.bind_texture, Gl.delete_texture, Gl.active_texture,
    Gl.tex_filter, Gl.tex_wrap, Gl.flip_y, Gl.tex_image_from_image,
    GlImage.load, GlImage.poll,
    Gl.buffer_data_f32, Gl.buffer_data_i32, Gl.uniform_matrix4, Gl.f32_buf, Gl.i32_buf,
}
use forge_math::{Mat4, mat4_to_list, Vec3, f64_of_i64}
use forge_render::{
    Color, color_r, color_g, color_b, color_a,
    MeshData, mesh_vertices, mesh_indices, mesh_index_count,
    ShaderKind, shader_kind_code, TextureHandle, texture_handle_id, texture_is_none,
    TextureDesc, texture_url, texture_is_linear, texture_repeats,
    Assets, assets_mesh, assets_texture, assets_mesh_ids, assets_texture_ids,
    DrawCall, draw_call_mesh, draw_call_shader, draw_call_tint, draw_call_texture,
    draw_call_model, draw_call_unlit,
    FramePlan, plan_clears, plan_clear_color, plan_view, plan_projection, plan_draws, plan_light,
    plan_shadows, plan_light_view_projection, plan_casters,
    Light, light_toward, light_diffuse, light_ambient, light_map_size
}
use lib::shaders {
    vertex_source, flat_fragment_source, textured_fragment_source,
    depth_vertex_source, depth_fragment_source,
    vertex_stride_bytes, uv_offset_bytes, normal_offset_bytes
}

// ── Uniform slots ───────────────────────────────────────────────────

/// A uniform location that may be absent (optimised out, or not declared).
type Slot {
    slot_some (u : GlUniform),
    slot_none
}

instance Copy Slot {
    def copy (s : Slot) : Pair Slot Slot := Pair.pair s s
}

def slot_of (o : Option GlUniform) : Slot :=
    match o {
        Option.some u => Slot.slot_some u,
        Option.none => Slot.slot_none
    }

def index_of (o : Option I64) : I64 :=
    match o {
        Option.some i => i,
        Option.none => I64.sub 0 1
    }

def upload_matrix (ctx : GlContext) (u : GlUniform) (m : Mat4) : IO Unit := do {
    let b <- Gl.f32_buf (mat4_to_list m);
    let _ <- Gl.uniform_matrix4 ctx u (Shared.of b);
    IO.pure unit
}

def set_matrix (ctx : GlContext) (s : Slot) (m : Mat4) : IO Unit :=
    match s {
        Slot.slot_some u => upload_matrix ctx u m,
        Slot.slot_none => IO.pure unit
    }

def set_color (ctx : GlContext) (s : Slot) (c : Color) : IO Unit :=
    match s {
        Slot.slot_some u => Gl.uniform4f ctx u (color_r c) (color_g c) (color_b c) (color_a c),
        Slot.slot_none => IO.pure unit
    }

def set_float (ctx : GlContext) (s : Slot) (x : F64) : IO Unit :=
    match s {
        Slot.slot_some u => Gl.uniform1f ctx u x,
        Slot.slot_none => IO.pure unit
    }

def set_vec3 (ctx : GlContext) (s : Slot) (v : Vec3) : IO Unit :=
    match s {
        Slot.slot_some u => Gl.uniform3f ctx u v.x v.y v.z,
        Slot.slot_none => IO.pure unit
    }

def set_int (ctx : GlContext) (s : Slot) (x : I64) : IO Unit :=
    match s {
        Slot.slot_some u => Gl.uniform1i ctx u x,
        Slot.slot_none => IO.pure unit
    }

// ── Programs ────────────────────────────────────────────────────────

/// A linked program with its attribute indices (-1 when unused) and slots.
struct ProgramInfo {
    program : GlProgram,
    a_position : I64,
    a_uv : I64,
    a_normal : I64,
    u_model : Slot,
    u_view : Slot,
    u_proj : Slot,
    u_tint : Slot,
    u_tex : Slot,
    u_light_dir : Slot,
    u_light_color : Slot,
    u_ambient : Slot,
    u_unlit : Slot,
    u_light_vp : Slot,
    u_shadow : Slot,
    u_shadows : Slot,
    u_shadow_texel : Slot
}

instance Copy ProgramInfo {
    def copy (p : ProgramInfo) : Pair ProgramInfo ProgramInfo := Pair.pair p p
}

def program_info_new (program : GlProgram) (a_position : I64) (a_uv : I64) (a_normal : I64)
    (u_model : Slot) (u_view : Slot) (u_proj : Slot) (u_tint : Slot) (u_tex : Slot)
    (u_light_dir : Slot) (u_light_color : Slot) (u_ambient : Slot) (u_unlit : Slot)
    (u_light_vp : Slot) (u_shadow : Slot) (u_shadows : Slot) (u_shadow_texel : Slot)
    : ProgramInfo :=
    { program := program, a_position := a_position, a_uv := a_uv, a_normal := a_normal,
      u_model := u_model, u_view := u_view, u_proj := u_proj, u_tint := u_tint,
      u_tex := u_tex, u_light_dir := u_light_dir, u_light_color := u_light_color,
      u_ambient := u_ambient, u_unlit := u_unlit, u_light_vp := u_light_vp,
      u_shadow := u_shadow, u_shadows := u_shadows, u_shadow_texel := u_shadow_texel
      : ProgramInfo }

/// Resolve every location once, at link time (`getUniformLocation` is a
/// setup-only call: it allocates a host-side entry per lookup).
def program_info (ctx : GlContext) (p : GlProgram) : IO ProgramInfo := do {
    let a_position <- Gl.attrib_location ctx p "a_position";
    let a_uv <- Gl.attrib_location ctx p "a_uv";
    let a_normal <- Gl.attrib_location ctx p "a_normal";
    let u_model <- Gl.uniform_location ctx p "u_model";
    let u_view <- Gl.uniform_location ctx p "u_view";
    let u_proj <- Gl.uniform_location ctx p "u_proj";
    let u_tint <- Gl.uniform_location ctx p "u_tint";
    let u_tex <- Gl.uniform_location ctx p "u_tex";
    let u_light_dir <- Gl.uniform_location ctx p "u_light_dir";
    let u_light_color <- Gl.uniform_location ctx p "u_light_color";
    let u_ambient <- Gl.uniform_location ctx p "u_ambient";
    let u_unlit <- Gl.uniform_location ctx p "u_unlit";
    let u_light_vp <- Gl.uniform_location ctx p "u_light_vp";
    let u_shadow <- Gl.uniform_location ctx p "u_shadow";
    let u_shadows <- Gl.uniform_location ctx p "u_shadows";
    let u_shadow_texel <- Gl.uniform_location ctx p "u_shadow_texel";
    IO.pure (program_info_new p (index_of a_position) (index_of a_uv) (index_of a_normal)
                (slot_of u_model) (slot_of u_view) (slot_of u_proj) (slot_of u_tint)
                (slot_of u_tex) (slot_of u_light_dir) (slot_of u_light_color)
                (slot_of u_ambient) (slot_of u_unlit) (slot_of u_light_vp)
                (slot_of u_shadow) (slot_of u_shadows) (slot_of u_shadow_texel))
}

def program_linked (ctx : GlContext) (p : GlProgram) : IO (Result String ProgramInfo) := do {
    let info <- program_info ctx p;
    IO.pure (Result.ok info)
}

/// Compile + link one program; the error is the driver's info log.
def build_program (ctx : GlContext) (fragment : String) : IO (Result String ProgramInfo) :=
    build_program_from ctx vertex_source fragment

def build_program_from (ctx : GlContext) (vertex : String) (fragment : String)
    : IO (Result String ProgramInfo) := do {
    let built <- Gl.program ctx vertex fragment;
    match built {
        Result.err e => IO.pure (Result.err e),
        Result.ok p => program_linked ctx p,
    }
}

/// Both programs, indexed by `shader_kind_code`.
struct Programs {
    flat : ProgramInfo,
    textured : ProgramInfo
}

instance Copy Programs {
    def copy (p : Programs) : Pair Programs Programs := Pair.pair p p
}

def programs_new (flat : ProgramInfo) (textured : ProgramInfo) : Programs :=
    { flat := flat, textured := textured : Programs }

def programs_with_flat (ctx : GlContext) (flat : ProgramInfo) : IO (Result String Programs) := do {
    let built <- build_program ctx textured_fragment_source;
    match built {
        Result.err e => IO.pure (Result.err (String.concat "textured shader: " e)),
        Result.ok textured => IO.pure (Result.ok (programs_new flat textured)),
    }
}

def build_programs (ctx : GlContext) : IO (Result String Programs) := do {
    let built <- build_program ctx flat_fragment_source;
    match built {
        Result.err e => IO.pure (Result.err (String.concat "flat shader: " e)),
        Result.ok flat => programs_with_flat ctx flat,
    }
}

// ── GPU-side assets ─────────────────────────────────────────────────

/// An uploaded mesh: its vertex buffer, index buffer and index count.
struct GpuMesh {
    vbo : GlBuffer,
    ibo : GlBuffer,
    count : I64
}

instance Copy GpuMesh {
    def copy (m : GpuMesh) : Pair GpuMesh GpuMesh := Pair.pair m m
}

def gpu_mesh (vbo : GlBuffer) (ibo : GlBuffer) (count : I64) : GpuMesh :=
    { vbo := vbo, ibo := ibo, count := count : GpuMesh }

/// A texture and the image it loads from. `state`: 0 loading, 1 ready,
/// 2 failed (the `GlImage.poll` convention).
struct GpuTexture {
    texture : GlTexture,
    image : GlImage,
    state : I64,
    linear : Bool,
    repeats : Bool
}

instance Copy GpuTexture {
    def copy (t : GpuTexture) : Pair GpuTexture GpuTexture := Pair.pair t t
}

def gpu_texture (texture : GlTexture) (image : GlImage) (state : I64) (linear : Bool) (repeats : Bool)
    : GpuTexture :=
    { texture := texture, image := image, state := state, linear := linear, repeats := repeats
      : GpuTexture }

// ── Shadow map state ────────────────────────────────────────────────

/// The shadow map's GL objects: the depth texture, the framebuffer it is
/// attached to, its size in texels, and the depth-only program.
struct ShadowMap {
    framebuffer : GlFramebuffer,
    texture : GlTexture,
    size : I64,
    depth : ProgramInfo
}

instance Copy ShadowMap {
    def copy (m : ShadowMap) : Pair ShadowMap ShadowMap := Pair.pair m m
}

def shadow_map (framebuffer : GlFramebuffer) (texture : GlTexture) (size : I64) (depth : ProgramInfo)
    : ShadowMap :=
    { framebuffer := framebuffer, texture := texture, size := size, depth := depth : ShadowMap }

/// Not tried yet (no frame has asked for shadows on this context), tried
/// and unavailable, or ready.
type ShadowState {
    shadow_untried,
    shadow_failed,
    shadow_ready (m : ShadowMap)
}

instance Copy ShadowState {
    def copy (s : ShadowState) : Pair ShadowState ShadowState := Pair.pair s s
}

// ── The renderer ────────────────────────────────────────────────────

/// A WebGL backend bound to one canvas. `Copy` (identity): it is a handle to
/// GPU state, and the mutable parts are behind `Ref`s.
pub struct WebGlRenderer {
    canvas : Node,
    ctx : GlContext,
    programs : Ref Programs,
    meshes : Ref (HashMap I64 GpuMesh),
    textures : Ref (HashMap I64 GpuTexture),
    assets : Ref Assets,
    lost : Ref Bool,
    shadow : Ref ShadowState
}

pub instance Copy WebGlRenderer {
    def copy (r : WebGlRenderer) : Pair WebGlRenderer WebGlRenderer := Pair.pair r r
}

def renderer_new (canvas : Node) (ctx : GlContext) (programs : Ref Programs)
    (meshes : Ref (HashMap I64 GpuMesh)) (textures : Ref (HashMap I64 GpuTexture))
    (assets : Ref Assets) (lost : Ref Bool) (shadow : Ref ShadowState) : WebGlRenderer :=
    { canvas := canvas, ctx := ctx, programs := programs, meshes := meshes,
      textures := textures, assets := assets, lost := lost, shadow := shadow
      : WebGlRenderer }

// ── Uploads ─────────────────────────────────────────────────────────

def upload_mesh (r : WebGlRenderer) (id : I64) (m : MeshData) : IO Unit := do {
    let ctx : GlContext := r.ctx;
    let vbo <- Gl.create_buffer ctx;
    let _ <- Gl.bind_buffer ctx GlBufferTarget.array vbo;
    let vertices <- Gl.f32_buf (mesh_vertices m);
    let _ <- Gl.buffer_data_f32 ctx GlBufferTarget.array (Shared.of vertices) GlUsage.static_draw;
    let ibo <- Gl.create_buffer ctx;
    let _ <- Gl.bind_buffer ctx GlBufferTarget.element_array ibo;
    let indices <- Gl.i32_buf (mesh_indices m);
    let _ <- Gl.buffer_data_i32 ctx GlBufferTarget.element_array (Shared.of indices) GlUsage.static_draw;
    let g : GpuMesh := gpu_mesh vbo ibo (mesh_index_count m);
    let _ <- Ref.update r.meshes (fn (t : HashMap I64 GpuMesh) => Map.insert id g t);
    IO.pure unit
}

def upload_mesh_id (r : WebGlRenderer) (assets : Assets) (id : I64) : IO Unit :=
    match assets_mesh assets id {
        Option.some m => upload_mesh r id m,
        Option.none => IO.pure unit
    }

#[terminating]
def upload_meshes (r : WebGlRenderer) (assets : Assets) (ids : List I64) : IO Unit :=
    match ids {
        List.empty => IO.pure unit,
        List.cons id rest => do {
            let _ <- upload_mesh_id r assets id;
            upload_meshes r assets rest
        }
    }

/// Create the texture object and START its image loading; the pixels are
/// uploaded by `poll_textures` on the frame the image becomes ready.
def start_texture (r : WebGlRenderer) (id : I64) (t : TextureDesc) : IO Unit := do {
    let texture <- Gl.create_texture r.ctx;
    let image <- GlImage.load (texture_url t);
    let g : GpuTexture := gpu_texture texture image 0 (texture_is_linear t) (texture_repeats t);
    let _ <- Ref.update r.textures (fn (m : HashMap I64 GpuTexture) => Map.insert id g m);
    IO.pure unit
}

def start_texture_id (r : WebGlRenderer) (assets : Assets) (id : I64) : IO Unit :=
    match assets_texture assets id {
        Option.some t => start_texture r id t,
        Option.none => IO.pure unit
    }

#[terminating]
def start_textures (r : WebGlRenderer) (assets : Assets) (ids : List I64) : IO Unit :=
    match ids {
        List.empty => IO.pure unit,
        List.cons id rest => do {
            let _ <- start_texture_id r assets id;
            start_textures r assets rest
        }
    }

/// Upload every mesh and start every texture in `assets`, replacing the
/// tables (the caller releases the old objects first when there are any).
def upload_all (r : WebGlRenderer) (assets : Assets) : IO Unit := do {
    let _ <- Ref.set r.meshes (Map.empty : HashMap I64 GpuMesh);
    let _ <- Ref.set r.textures (Map.empty : HashMap I64 GpuTexture);
    let _ <- Ref.set r.assets assets;
    let _ <- upload_meshes r assets (assets_mesh_ids assets);
    start_textures r assets (assets_texture_ids assets)
}

def set_texture_state (r : WebGlRenderer) (id : I64) (g : GpuTexture) (state : I64) : IO Unit := do {
    let next : GpuTexture := gpu_texture g.texture g.image state g.linear g.repeats;
    let _ <- Ref.update r.textures (fn (m : HashMap I64 GpuTexture) => Map.insert id next m);
    IO.pure unit
}

/// `GlFilter`/`GlWrap` have no `Copy` instance in `web_wasm`, so each use
/// builds a fresh value.
def filter_of (linear : Bool) : GlFilter := if linear then GlFilter.linear else GlFilter.nearest

def wrap_of (repeats : Bool) : GlWrap := if repeats then GlWrap.repeat else GlWrap.clamp_to_edge

/// The image arrived: upload it and set its sampling state.
def finish_texture (r : WebGlRenderer) (id : I64) (g : GpuTexture) : IO Unit := do {
    let ctx : GlContext := r.ctx;
    let _ <- Gl.bind_texture ctx GlTextureTarget.texture_2d g.texture;
    let _ <- Gl.flip_y ctx true;
    let ok <- Gl.tex_image_from_image ctx GlTextureTarget.texture_2d g.image;
    let _ <- Gl.tex_filter ctx GlTextureTarget.texture_2d (filter_of g.linear) (filter_of g.linear);
    let _ <- Gl.tex_wrap ctx GlTextureTarget.texture_2d (wrap_of g.repeats) (wrap_of g.repeats);
    set_texture_state r id g (if ok then 1 else 2)
}

def poll_loading (r : WebGlRenderer) (id : I64) (g : GpuTexture) : IO Unit := do {
    let status <- GlImage.poll g.image;
    if I64.beq status 1 then finish_texture r id g
    else if I64.beq status 2 then set_texture_state r id g 2
    else IO.pure unit
}

def poll_known (r : WebGlRenderer) (id : I64) (g : GpuTexture) : IO Unit :=
    if I64.beq g.state 0 then poll_loading r id g else IO.pure unit

def poll_texture (r : WebGlRenderer) (id : I64) : IO Unit := do {
    let table <- Ref.get r.textures;
    match Map.lookup id table {
        Option.some g => poll_known r id g,
        Option.none => IO.pure unit,
    }
}

#[terminating]
def poll_textures (r : WebGlRenderer) (ids : List I64) : IO Unit :=
    match ids {
        List.empty => IO.pure unit,
        List.cons id rest => do {
            let _ <- poll_texture r id;
            poll_textures r rest
        }
    }

// ── Releasing ───────────────────────────────────────────────────────

def release_mesh (r : WebGlRenderer) (g : GpuMesh) : IO Unit := do {
    let _ <- Gl.delete_buffer r.ctx g.vbo;
    Gl.delete_buffer r.ctx g.ibo
}

def release_mesh_id (r : WebGlRenderer) (id : I64) : IO Unit := do {
    let table <- Ref.get r.meshes;
    match Map.lookup id table {
        Option.some g => release_mesh r g,
        Option.none => IO.pure unit,
    }
}

#[terminating]
def release_meshes (r : WebGlRenderer) (ids : List I64) : IO Unit :=
    match ids {
        List.empty => IO.pure unit,
        List.cons id rest => do {
            let _ <- release_mesh_id r id;
            release_meshes r rest
        }
    }

def release_texture (r : WebGlRenderer) (g : GpuTexture) : IO Unit :=
    Gl.delete_texture r.ctx g.texture

def release_texture_id (r : WebGlRenderer) (id : I64) : IO Unit := do {
    let table <- Ref.get r.textures;
    match Map.lookup id table {
        Option.some g => release_texture r g,
        Option.none => IO.pure unit,
    }
}

#[terminating]
def release_textures (r : WebGlRenderer) (ids : List I64) : IO Unit :=
    match ids {
        List.empty => IO.pure unit,
        List.cons id rest => do {
            let _ <- release_texture_id r id;
            release_textures r rest
        }
    }

/// Delete every buffer and texture uploaded for the current assets.
def release_all (r : WebGlRenderer) : IO Unit := do {
    let assets <- Ref.get r.assets;
    release_assets r assets
}

/// Split out so `assets` is a typed (`Copy`) parameter: a `<-`-bound value
/// is checked before its type is known, so reading it twice trips the
/// affine gate even with an annotation.
def release_assets (r : WebGlRenderer) (assets : Assets) : IO Unit := do {
    let _ <- release_meshes r (assets_mesh_ids assets);
    release_textures r (assets_texture_ids assets)
}

// ── Setup ───────────────────────────────────────────────────────────

/// The fixed pipeline state: depth-tested, alpha-blended, nothing culled (a
/// quad is visible from both sides).
def init_state (ctx : GlContext) : IO Unit := do {
    let _ <- Gl.enable ctx GlCap.depth_test;
    let _ <- Gl.depth_func ctx GlCompare.lequal;
    let _ <- Gl.enable ctx GlCap.blend;
    Gl.blend_func ctx GlBlendFactor.src_alpha GlBlendFactor.one_minus_src_alpha
}

def finish_setup (canvas : Node) (ctx : GlContext) (assets : Assets) (ps : Programs)
    : IO (Result String WebGlRenderer) := do {
    let programs <- Ref.new ps;
    let meshes <- Ref.new (Map.empty : HashMap I64 GpuMesh);
    let textures <- Ref.new (Map.empty : HashMap I64 GpuTexture);
    let held <- Ref.new assets;
    let lost <- Ref.new false;
    let shadow <- Ref.new ShadowState.shadow_untried;
    let r : WebGlRenderer := renderer_new canvas ctx programs meshes textures held lost shadow;
    let _ <- init_state ctx;
    let _ <- upload_all r assets;
    IO.pure (Result.ok r)
}

def setup_programs (canvas : Node) (ctx : GlContext) (assets : Assets)
    : IO (Result String WebGlRenderer) := do {
    let built <- build_programs ctx;
    match built {
        Result.err e => IO.pure (Result.err e),
        Result.ok ps => finish_setup canvas ctx assets ps,
    }
}

def setup_context (canvas : Node) (ctx : GlContext) (assets : Assets)
    : IO (Result String WebGlRenderer) := do {
    let wide <- Gl.has_uint_indices ctx;
    if wide
    then setup_programs canvas ctx assets
    else IO.pure (Result.err "webgl: 32-bit element indices unavailable (OES_element_index_uint)")
}

/// Bring up WebGL on an EXISTING canvas (one an oak view rendered, say) and
/// upload `assets`. The drawing buffer is fitted to the canvas's layout size
/// first. `err` carries the reason: no context, no 32-bit indices, or a
/// shader's info log.
pub def webgl_attach (canvas : Node) (assets : Assets) : IO (Result String WebGlRenderer) := do {
    let _ <- Canvas.fit canvas;
    let found <- Gl.context canvas GlOptions.default;
    match found {
        Option.none => IO.pure (Result.err "webgl: the canvas has no WebGL context"),
        Option.some ctx => setup_context canvas ctx assets,
    }
}

/// Create a `<canvas id="forge">` filling the mount root, then
/// `webgl_attach` to it.
pub def webgl_create (assets : Assets) : IO (Result String WebGlRenderer) := do {
    let root <- Dom.root;
    let canvas <- Dom.create "canvas";
    let _ <- Dom.set_attr canvas "id" "forge";
    let _ <- Dom.set_attr canvas "style" "width: 100%; height: 100%; display: block";
    let _ <- Dom.append root canvas;
    webgl_attach canvas assets
}

// ── Queries ─────────────────────────────────────────────────────────

/// A width and height, in whatever unit the function that returns it says.
pub struct Size2 {
    width : F64,
    height : F64
}

pub instance Copy Size2 {
    def copy (s : Size2) : Pair Size2 Size2 := Pair.pair s s
}

def size2 (width : F64) (height : F64) : Size2 := { width := width, height := height : Size2 }

pub def size_width (s : Size2) : F64 := s.width

pub def size_height (s : Size2) : F64 := s.height

/// `width / height`, or 1 for a degenerate size.
pub def size_aspect (s : Size2) : F64 :=
    if s.height > 0.0 then s.width / s.height else 1.0

def size_of_pair (p : Pair F64 F64) : Size2 :=
    match p { Pair.pair w h => size2 w h }

/// The canvas's LAYOUT size in CSS pixels -- the space pointer coordinates
/// (`offsetX`/`offsetY`) are in, so the one picking wants.
pub def webgl_client_size (r : WebGlRenderer) : IO Size2 := do {
    let p <- Canvas.client_size r.canvas;
    IO.pure (size_of_pair p)
}

/// The canvas the renderer draws into.
pub def webgl_canvas (r : WebGlRenderer) : Node := r.canvas

/// 2 for a WebGL2 context, 1 for the WebGL1 fallback.
pub def webgl_version (r : WebGlRenderer) : IO I64 := Gl.version r.ctx

/// Is the context currently lost?
pub def webgl_is_lost (r : WebGlRenderer) : IO Bool := Gl.is_lost r.ctx

/// Refit the drawing buffer to the canvas's layout size x devicePixelRatio.
/// True when it changed (the caller's projection aspect is then stale). Safe
/// to call every frame.
pub def webgl_resize (r : WebGlRenderer) : IO Bool := Canvas.fit r.canvas

/// How many meshes are uploaded.
pub def webgl_mesh_count (r : WebGlRenderer) : IO I64 := do {
    let assets : Assets <- Ref.get r.assets;
    IO.pure (List.length (assets_mesh_ids assets))
}

// ── Replacing assets / rebuilding ───────────────────────────────────

/// Swap the asset tables: delete what was uploaded, upload `assets`.
pub def webgl_set_assets (r : WebGlRenderer) (assets : Assets) : IO Unit := do {
    let _ <- release_all r;
    upload_all r assets
}

def rebuilt (r : WebGlRenderer) (ps : Programs) : IO Bool := do {
    let assets : Assets <- Ref.get r.assets;
    let _ <- Ref.set r.programs ps;
    let _ <- init_state r.ctx;
    let _ <- upload_all r assets;
    let _ <- Ref.set r.lost false;
    let _ <- Ref.set r.shadow ShadowState.shadow_untried;
    IO.pure true
}

/// Recreate every GL object after a context was restored: relink the
/// programs, restore the pipeline state, re-upload the current assets.
/// Nothing is deleted first -- a lost context already took it all. False if
/// a program failed to relink (the renderer then stays marked lost and the
/// next frame tries again).
pub def webgl_rebuild (r : WebGlRenderer) : IO Bool := do {
    let built <- build_programs r.ctx;
    match built {
        Result.err _ => IO.pure false,
        Result.ok ps => rebuilt r ps,
    }
}

// ── Drawing ─────────────────────────────────────────────────────────

/// The texture a draw samples, once its image is on the GPU.
type TextureChoice {
    use_texture (t : GlTexture),
    no_texture
}

def choice_of (o : Option GpuTexture) : TextureChoice :=
    match o {
        Option.none => TextureChoice.no_texture,
        Option.some g0 =>
            let g : GpuTexture := g0 in
            if I64.beq g.state 1 then TextureChoice.use_texture g.texture else TextureChoice.no_texture
    }

def lookup_texture (r : WebGlRenderer) (id : I64) : IO TextureChoice := do {
    let table <- Ref.get r.textures;
    IO.pure (choice_of (Map.lookup id table))
}

/// A textured draw samples its texture only when the material asks for the
/// textured shader, names a texture, and that texture is ready.
def texture_for (r : WebGlRenderer) (shader : ShaderKind) (h : TextureHandle) : IO TextureChoice :=
    if I64.beq (shader_kind_code shader) 1 && Bool.not (texture_is_none h)
    then lookup_texture r (texture_handle_id h)
    else IO.pure TextureChoice.no_texture

/// Point one attribute at the bound vertex buffer (skipped when the program
/// does not use it).
def attribute (ctx : GlContext) (index : I64) (size : I64) (offset : I64) : IO Unit :=
    if I64.lt index 0
    then IO.pure unit
    else do {
        let _ <- Gl.vertex_attrib_pointer ctx index size GlAttribType.f32 false vertex_stride_bytes offset;
        Gl.enable_vertex_attrib ctx index
    }

/// The draw itself, with `info`'s program: per-draw uniforms, buffers,
/// attribute layout, `drawElements`.
def issue (r : WebGlRenderer) (info : ProgramInfo) (d : DrawCall) (g : GpuMesh) : IO I64 := do {
    let ctx : GlContext := r.ctx;
    let _ <- Gl.use_program ctx info.program;
    let _ <- set_matrix ctx info.u_model (draw_call_model d);
    let _ <- set_color ctx info.u_tint (draw_call_tint d);
    let _ <- set_float ctx info.u_unlit (if draw_call_unlit d then 1.0 else 0.0);
    let _ <- Gl.bind_buffer ctx GlBufferTarget.array g.vbo;
    let _ <- Gl.bind_buffer ctx GlBufferTarget.element_array g.ibo;
    let _ <- attribute ctx info.a_position 3 0;
    let _ <- attribute ctx info.a_uv 2 uv_offset_bytes;
    let _ <- attribute ctx info.a_normal 3 normal_offset_bytes;
    let _ <- Gl.draw_elements ctx GlPrimitive.triangles g.count 0;
    IO.pure 1
}

def issue_textured (r : WebGlRenderer) (info : ProgramInfo) (d : DrawCall) (g : GpuMesh) (t : GlTexture)
    : IO I64 := do {
    let ctx : GlContext := r.ctx;
    let _ <- Gl.use_program ctx info.program;
    let _ <- Gl.active_texture ctx 0;
    let _ <- Gl.bind_texture ctx GlTextureTarget.texture_2d t;
    let _ <- set_int ctx info.u_tex 0;
    issue r info d g
}

def draw_uploaded (r : WebGlRenderer) (ps : Programs) (d : DrawCall) (g : GpuMesh) : IO I64 := do {
    let choice <- texture_for r (draw_call_shader d) (draw_call_texture d);
    match choice {
        TextureChoice.use_texture t => issue_textured r ps.textured d g t,
        TextureChoice.no_texture => issue r ps.flat d g,
    }
}

/// One draw: 1 when issued, 0 when its mesh is not uploaded.
def draw_one (r : WebGlRenderer) (ps : Programs) (d : DrawCall) : IO I64 := do {
    let table <- Ref.get r.meshes;
    match Map.lookup (draw_call_mesh d) table {
        Option.some g => draw_uploaded r ps d g,
        Option.none => IO.pure 0,
    }
}

#[terminating]
def draw_go (r : WebGlRenderer) (ps : Programs) (draws : List DrawCall) (issued : I64) : IO I64 :=
    match draws {
        List.empty => IO.pure issued,
        List.cons d rest => do {
            let n <- draw_one r ps d;
            draw_go r ps rest (I64.add issued n)
        }
    }

/// A one-arm `Pair` match in its own def (a `match` on a `Pair` is a
/// statement inside a `do` block).
def viewport_to (ctx : GlContext) (size : Pair I64 I64) : IO Unit :=
    match size { Pair.pair w h => Gl.viewport ctx 0 0 w h }

def clear_to (ctx : GlContext) (c : Color) : IO Unit := do {
    let _ <- Gl.clear_color ctx (color_r c) (color_g c) (color_b c) (color_a c);
    let mask : GlClear := { color := true, depth := true, stencil := false };
    Gl.clear ctx mask
}

/// The camera and the light are per FRAME, so each program gets them once,
/// not once per draw.
def prime (ctx : GlContext) (info : ProgramInfo) (view : Mat4) (projection : Mat4) (light : Light) : IO Unit := do {
    let _ <- Gl.use_program ctx info.program;
    let _ <- set_matrix ctx info.u_view view;
    let _ <- set_matrix ctx info.u_proj projection;
    let _ <- set_vec3 ctx info.u_light_dir (light_toward light);
    let _ <- set_vec3 ctx info.u_light_color (light_diffuse light);
    set_float ctx info.u_ambient (light_ambient light)
}

def live_frame (r : WebGlRenderer) (plan : FramePlan) : IO I64 := do {
    let ps <- Ref.get r.programs;
    let assets <- Ref.get r.assets;
    let _ <- poll_textures r (assets_texture_ids assets);
    live_frame_with r ps plan
}

def live_frame_with (r : WebGlRenderer) (ps : Programs) (plan : FramePlan) : IO I64 := do {
    let shadow <- shadow_for r plan;
    live_frame_lit r ps plan shadow
}

def live_frame_lit (r : WebGlRenderer) (ps : Programs) (plan : FramePlan) (shadow : ShadowState)
    : IO I64 := do {
    let ctx : GlContext := r.ctx;
    let _ <- shadow_pass r ps plan shadow;
    let size <- Gl.drawing_buffer_size ctx;
    let _ <- viewport_to ctx size;
    let _ <- if plan_clears plan then clear_to ctx (plan_clear_color plan) else IO.pure unit;
    let _ <- prime ctx ps.flat (plan_view plan) (plan_projection plan) (plan_light plan);
    let _ <- prime ctx ps.textured (plan_view plan) (plan_projection plan) (plan_light plan);
    draw_go r ps (plan_draws plan) 0
}

// ── Shadows ─────────────────────────────────────────────────────────

def shadow_store (r : WebGlRenderer) (s : ShadowState) : IO ShadowState := do {
    let _ <- Ref.set r.shadow s;
    IO.pure s
}

/// Undo a half-built shadow map.
def shadow_give_up (r : WebGlRenderer) (fb : GlFramebuffer) (t : GlTexture) : IO ShadowState := do {
    let ctx : GlContext := r.ctx;
    let _ <- Gl.bind_default_framebuffer ctx;
    let _ <- Gl.delete_framebuffer ctx fb;
    let _ <- Gl.delete_texture ctx t;
    IO.pure ShadowState.shadow_failed
}

def shadow_with_program (r : WebGlRenderer) (fb : GlFramebuffer) (t : GlTexture) (size : I64)
    : IO ShadowState := do {
    let built <- build_program_from r.ctx depth_vertex_source depth_fragment_source;
    match built {
        Result.err _ => shadow_give_up r fb t,
        Result.ok depth => IO.pure (ShadowState.shadow_ready (shadow_map fb t size depth)),
    }
}

def shadow_attach (r : WebGlRenderer) (fb : GlFramebuffer) (t : GlTexture) (size : I64)
    : IO ShadowState := do {
    let ctx : GlContext := r.ctx;
    let _ <- Gl.bind_framebuffer ctx fb;
    let _ <- Gl.framebuffer_texture ctx GlAttachment.depth t;
    let complete <- Gl.framebuffer_complete ctx;
    let _ <- Gl.bind_default_framebuffer ctx;
    if complete then shadow_with_program r fb t size else shadow_give_up r fb t
}

def shadow_framebuffer (r : WebGlRenderer) (t : GlTexture) (size : I64) : IO ShadowState := do {
    let fb <- Gl.create_framebuffer r.ctx;
    shadow_attach r fb t size
}

/// Allocate `t` as a `size`^2 depth texture (nearest, clamped: depth
/// textures take no filtering).
def shadow_allocate (r : WebGlRenderer) (t : GlTexture) (size : I64) : IO ShadowState := do {
    let ctx : GlContext := r.ctx;
    let _ <- Gl.bind_texture ctx GlTextureTarget.texture_2d t;
    let _ <- Gl.tex_filter ctx GlTextureTarget.texture_2d GlFilter.nearest GlFilter.nearest;
    let _ <- Gl.tex_wrap ctx GlTextureTarget.texture_2d GlWrap.clamp_to_edge GlWrap.clamp_to_edge;
    let ok <- Gl.tex_image_depth ctx size size;
    if ok
    then shadow_framebuffer r t size
    else do {
        let _ <- Gl.delete_texture ctx t;
        IO.pure ShadowState.shadow_failed
    }
}

def shadow_create (r : WebGlRenderer) (size : I64) : IO ShadowState := do {
    let t <- Gl.create_texture r.ctx;
    let made <- shadow_allocate r t size;
    shadow_store r made
}

def shadow_settle (r : WebGlRenderer) (size : I64) (s : ShadowState) : IO ShadowState :=
    match s {
        ShadowState.shadow_untried => shadow_create r size,
        ShadowState.shadow_failed => IO.pure ShadowState.shadow_failed,
        ShadowState.shadow_ready m => IO.pure (ShadowState.shadow_ready m)
    }

/// This frame's shadow map: created on the first frame that asks. A frame
/// that does not ask gets `shadow_untried` (nothing to draw), whatever the
/// stored state is.
def shadow_for (r : WebGlRenderer) (plan : FramePlan) : IO ShadowState :=
    if plan_shadows plan
    then do {
        let s <- Ref.get r.shadow;
        shadow_settle r (light_map_size (plan_light plan)) s
    }
    else IO.pure ShadowState.shadow_untried

/// One caster into the shadow map (the depth program is in use).
def depth_issue (ctx : GlContext) (info : ProgramInfo) (d : DrawCall) (g : GpuMesh) : IO I64 := do {
    let _ <- set_matrix ctx info.u_model (draw_call_model d);
    let _ <- Gl.bind_buffer ctx GlBufferTarget.array g.vbo;
    let _ <- Gl.bind_buffer ctx GlBufferTarget.element_array g.ibo;
    let _ <- attribute ctx info.a_position 3 0;
    let _ <- Gl.draw_elements ctx GlPrimitive.triangles g.count 0;
    IO.pure 1
}

def depth_one (r : WebGlRenderer) (info : ProgramInfo) (d : DrawCall) : IO I64 := do {
    let table <- Ref.get r.meshes;
    match Map.lookup (draw_call_mesh d) table {
        Option.some g => depth_issue r.ctx info d g,
        Option.none => IO.pure 0,
    }
}

#[terminating]
def depth_go (r : WebGlRenderer) (info : ProgramInfo) (draws : List DrawCall) (issued : I64) : IO I64 :=
    match draws {
        List.empty => IO.pure issued,
        List.cons d rest => do {
            let n <- depth_one r info d;
            depth_go r info rest (I64.add issued n)
        }
    }

/// Render the casters' depth from the light into the map: colour writes
/// off, polygon offset on (against acne), then everything back for the
/// main pass.
def depth_pass (r : WebGlRenderer) (m : ShadowMap) (plan : FramePlan) : IO Unit := do {
    let ctx : GlContext := r.ctx;
    let info : ProgramInfo := m.depth;
    let _ <- Gl.bind_framebuffer ctx m.framebuffer;
    let _ <- Gl.viewport ctx 0 0 m.size m.size;
    let _ <- Gl.color_mask ctx false false false false;
    let mask : GlClear := { color := false, depth := true, stencil := false };
    let _ <- Gl.clear ctx mask;
    let _ <- Gl.enable ctx GlCap.polygon_offset_fill;
    let _ <- Gl.polygon_offset ctx 2.0 4.0;
    let _ <- Gl.use_program ctx info.program;
    let _ <- set_matrix ctx info.u_light_vp (plan_light_view_projection plan);
    let _ <- depth_go r info (plan_casters plan) 0;
    let _ <- Gl.disable ctx GlCap.polygon_offset_fill;
    let _ <- Gl.color_mask ctx true true true true;
    Gl.bind_default_framebuffer ctx
}

/// The main pass's view of the map, per program.
def prime_shadow (ctx : GlContext) (info : ProgramInfo) (m : ShadowMap) (light_vp : Mat4) : IO Unit := do {
    let _ <- Gl.use_program ctx info.program;
    let _ <- set_matrix ctx info.u_light_vp light_vp;
    let _ <- set_int ctx info.u_shadow 1;
    let _ <- set_float ctx info.u_shadow_texel (1.0 / f64_of_i64 m.size);
    set_float ctx info.u_shadows 1.0
}

def prime_unshadowed (ctx : GlContext) (info : ProgramInfo) : IO Unit := do {
    let _ <- Gl.use_program ctx info.program;
    set_float ctx info.u_shadows 0.0
}

/// Depth pass, then the map on unit 1 (unit 0 stays the active one, for
/// material textures).
def shadowed (r : WebGlRenderer) (ps : Programs) (plan : FramePlan) (m : ShadowMap) : IO Unit := do {
    let ctx : GlContext := r.ctx;
    let _ <- depth_pass r m plan;
    let _ <- Gl.active_texture ctx 1;
    let _ <- Gl.bind_texture ctx GlTextureTarget.texture_2d m.texture;
    let _ <- Gl.active_texture ctx 0;
    let _ <- prime_shadow ctx ps.flat m (plan_light_view_projection plan);
    prime_shadow ctx ps.textured m (plan_light_view_projection plan)
}

def unshadowed (r : WebGlRenderer) (ps : Programs) : IO Unit := do {
    let _ <- prime_unshadowed r.ctx ps.flat;
    prime_unshadowed r.ctx ps.textured
}

def shadow_pass (r : WebGlRenderer) (ps : Programs) (plan : FramePlan) (s : ShadowState) : IO Unit :=
    match s {
        ShadowState.shadow_ready m => shadowed r ps plan m,
        ShadowState.shadow_untried => unshadowed r ps,
        ShadowState.shadow_failed => unshadowed r ps
    }

/// Whether the last shadowed frame had a working shadow map (false before
/// any frame asked, and when the context cannot make one).
pub def webgl_shadows_ready (r : WebGlRenderer) : IO Bool := do {
    let s <- Ref.get r.shadow;
    IO.pure (shadow_is_ready s)
}

def shadow_is_ready (s : ShadowState) : Bool :=
    match s {
        ShadowState.shadow_ready _ => true,
        ShadowState.shadow_untried => false,
        ShadowState.shadow_failed => false
    }

def restored_frame (r : WebGlRenderer) (plan : FramePlan) : IO I64 := do {
    let ok <- webgl_rebuild r;
    if ok then live_frame r plan else IO.pure (I64.sub 0 1)
}

def present_frame (r : WebGlRenderer) (plan : FramePlan) : IO I64 := do {
    let was_lost <- Ref.get r.lost;
    if was_lost then restored_frame r plan else live_frame r plan
}

def lost_frame (r : WebGlRenderer) : IO I64 := do {
    let _ <- Ref.set r.lost true;
    IO.pure (I64.sub 0 1)
}

/// Execute a frame. Returns the number of `drawElements` issued, or -1 when
/// nothing could be drawn because the context is lost.
///
/// There is no explicit present: the browser composites the drawing buffer
/// when the animation-frame callback returns.
pub def webgl_submit (r : WebGlRenderer) (plan : FramePlan) : IO I64 := do {
    let lost <- Gl.is_lost r.ctx;
    if lost then lost_frame r else present_frame r plan
}
