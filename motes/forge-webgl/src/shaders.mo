// forge-webgl: the two programs. Phase 9a, see ../../../PLAN.md.
//
// GLSL ES 1.00 on purpose: it compiles unchanged on a WebGL1 AND a WebGL2
// context, so the fallback path needs no second set of sources.
//
// One vertex shader serves both programs. The inputs are forge-render's
// `MeshData` layout (`a_position` xyz, `a_uv`, `a_normal`), and the matrices arrive
// separately -- model from the draw, view and projection from the frame's
// camera -- so nothing is multiplied on the CPU per draw.

/// `gl_Position = projection * view * model * position`. The world-space
/// normal goes to the fragment shader, which does the lighting (`u_model`
/// turns the normal; a non-uniform scale bends it slightly, which reads fine
/// for lighting this simple).
pub def vertex_source : String :=
    "attribute vec3 a_position; attribute vec2 a_uv; attribute vec3 a_normal; uniform mat4 u_model; uniform mat4 u_view; uniform mat4 u_proj; uniform mat4 u_light_vp; varying vec2 v_uv; varying vec3 v_normal; varying vec4 v_light_pos; void main() { v_uv = a_uv; v_normal = (u_model * vec4(a_normal, 0.0)).xyz; vec4 w = u_model * vec4(a_position, 1.0); v_light_pos = u_light_vp * w; gl_Position = u_proj * u_view * w; }"

/// The light, shared by both fragment shaders: forge-render's `Light` as
/// `u_light_dir` (unit, toward the sun), `u_light_color` (diffuse colour
/// times intensity) and `u_ambient`. `u_unlit` = 1 shows the colour as is.
///
/// Shadows: with `u_shadows` = 1 the diffuse term is scaled by how much of
/// a 3x3 neighbourhood of the shadow map (`u_shadow`, texel `u_shadow_texel`)
/// sees the fragment -- percentage-closer filtering done by hand, since GLSL
/// ES 1.00 has no shadow samplers. The bias grows as the surface turns away
/// from the light (acne on slopes); polygon offset in the depth pass does
/// the rest. Outside the shadow box everything is lit.
def lighting_source : String :=
    "uniform vec3 u_light_dir; uniform vec3 u_light_color; uniform float u_ambient; uniform float u_unlit; uniform sampler2D u_shadow; uniform float u_shadows; uniform float u_shadow_texel; varying vec3 v_normal; varying vec4 v_light_pos; float sunlit(float ndl) { if (u_shadows < 0.5) return 1.0; vec3 p = v_light_pos.xyz / v_light_pos.w * 0.5 + 0.5; if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0; float bias = max(0.004 * (1.0 - ndl), 0.001); float seen = 0.0; for (int i = -1; i <= 1; i++) { for (int j = -1; j <= 1; j++) { float d = texture2D(u_shadow, p.xy + vec2(float(i), float(j)) * u_shadow_texel).r; seen += (p.z - bias > d) ? 0.0 : 1.0; } } return seen / 9.0; } vec3 lit(vec3 c) { vec3 n = normalize(v_normal); float d = max(dot(n, u_light_dir), 0.0); float s = d > 0.0 ? sunlit(d) : 1.0; return mix(c * (vec3(u_ambient) + u_light_color * d * s), c, u_unlit); } "

/// Depth comparisons want highp where the fragment stage has it.
def precision_source : String :=
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"

/// `shader_flat`: the material's tint, lit.
pub def flat_fragment_source : String :=
    String.concat precision_source (String.concat "uniform vec4 u_tint; "
        (String.concat lighting_source "void main() { gl_FragColor = vec4(lit(u_tint.rgb), u_tint.a); }"))

/// `shader_textured`: the texture sample multiplied by the tint, lit.
pub def textured_fragment_source : String :=
    String.concat precision_source (String.concat "uniform vec4 u_tint; uniform sampler2D u_tex; varying vec2 v_uv; "
        (String.concat lighting_source "void main() { vec4 c = texture2D(u_tex, v_uv) * u_tint; gl_FragColor = vec4(lit(c.rgb), c.a); }"))

/// The shadow pass: position only, through the light's view-projection.
/// The fragment shader writes a constant (colour writes are masked off; only
/// depth lands in the shadow map).
pub def depth_vertex_source : String :=
    "attribute vec3 a_position; uniform mat4 u_model; uniform mat4 u_light_vp; void main() { gl_Position = u_light_vp * u_model * vec4(a_position, 1.0); }"

pub def depth_fragment_source : String :=
    "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"

/// Bytes per vertex: eight 32-bit floats (`mesh_stride` * 4).
pub def vertex_stride_bytes : I64 := 32

/// Byte offset of the uv pair within a vertex (after three position floats).
pub def uv_offset_bytes : I64 := 12

/// Byte offset of the normal within a vertex (after position and uv).
pub def normal_offset_bytes : I64 := 20
