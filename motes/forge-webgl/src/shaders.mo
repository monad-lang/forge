// forge-webgl: the two programs. Phase 9a, see ../../../PLAN.md.
//
// GLSL ES 1.00 on purpose: it compiles unchanged on a WebGL1 AND a WebGL2
// context, so the fallback path needs no second set of sources.
//
// One vertex shader serves both programs. The inputs are forge-render's
// `MeshData` layout (`a_position` xyz, `a_uv`, `a_normal`), and the matrices arrive
// separately -- model from the draw, view and projection from the frame's
// camera -- so nothing is multiplied on the CPU per draw.

/// `gl_Position = projection * view * model * position`, plus a light
/// factor: ambient 0.5 and a diffuse 0.5 from one fixed sun up and to the
/// side (`u_model` turns the normal; a non-uniform scale bends it slightly,
/// which reads fine for lighting this simple).
pub def vertex_source : String :=
    "attribute vec3 a_position; attribute vec2 a_uv; attribute vec3 a_normal; uniform mat4 u_model; uniform mat4 u_view; uniform mat4 u_proj; varying vec2 v_uv; varying float v_light; void main() { v_uv = a_uv; vec3 n = normalize((u_model * vec4(a_normal, 0.0)).xyz); v_light = 0.5 + 0.5 * max(dot(n, normalize(vec3(0.35, 0.85, 0.4))), 0.0); gl_Position = u_proj * u_view * u_model * vec4(a_position, 1.0); }"

/// `shader_flat`: the material's tint, lit.
pub def flat_fragment_source : String :=
    "precision mediump float; uniform vec4 u_tint; varying float v_light; void main() { gl_FragColor = vec4(u_tint.rgb * v_light, u_tint.a); }"

/// `shader_textured`: the texture sample multiplied by the tint, lit.
pub def textured_fragment_source : String :=
    "precision mediump float; uniform vec4 u_tint; uniform sampler2D u_tex; varying vec2 v_uv; varying float v_light; void main() { vec4 c = texture2D(u_tex, v_uv) * u_tint; gl_FragColor = vec4(c.rgb * v_light, c.a); }"

/// Bytes per vertex: eight 32-bit floats (`mesh_stride` * 4).
pub def vertex_stride_bytes : I64 := 32

/// Byte offset of the uv pair within a vertex (after three position floats).
pub def uv_offset_bytes : I64 := 12

/// Byte offset of the normal within a vertex (after position and uv).
pub def normal_offset_bytes : I64 := 20
