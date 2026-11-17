// forge-webgl: the two programs. Phase 9a, see ../../../PLAN.md.
//
// GLSL ES 1.00 on purpose: it compiles unchanged on a WebGL1 AND a WebGL2
// context, so the fallback path needs no second set of sources.
//
// One vertex shader serves both programs. The inputs are forge-render's
// `MeshData` layout (`a_position` xyz, `a_uv`), and the matrices arrive
// separately -- model from the draw, view and projection from the frame's
// camera -- so nothing is multiplied on the CPU per draw.

/// `gl_Position = projection * view * model * position`.
pub def vertex_source : String :=
    "attribute vec3 a_position; attribute vec2 a_uv; uniform mat4 u_model; uniform mat4 u_view; uniform mat4 u_proj; varying vec2 v_uv; void main() { v_uv = a_uv; gl_Position = u_proj * u_view * u_model * vec4(a_position, 1.0); }"

/// `shader_flat`: the material's tint, nothing else.
pub def flat_fragment_source : String :=
    "precision mediump float; uniform vec4 u_tint; void main() { gl_FragColor = u_tint; }"

/// `shader_textured`: the texture sample multiplied by the tint.
pub def textured_fragment_source : String :=
    "precision mediump float; uniform vec4 u_tint; uniform sampler2D u_tex; varying vec2 v_uv; void main() { gl_FragColor = texture2D(u_tex, v_uv) * u_tint; }"

/// Bytes per vertex: five 32-bit floats (`mesh_stride` * 4).
pub def vertex_stride_bytes : I64 := 20

/// Byte offset of the uv pair within a vertex (after three position floats).
pub def uv_offset_bytes : I64 := 12
