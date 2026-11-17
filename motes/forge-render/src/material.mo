// forge-render: materials, textures and the `Assets` table. Phase 9a, see
// ../../../PLAN.md.
//
// `MeshHandle`/`MaterialHandle` are bare ids on a `RenderCommand`; `Assets`
// is where an id becomes data: mesh geometry, a material (which shader, what
// tint, which texture) and a texture description. It is a PURE, persistent
// table -- a backend reads it to know what to upload, and `frame_plan`
// (plan.mo) reads it to resolve a frame.
//
// There are deliberately only two shader kinds (`flat` and `textured`): they
// are what the WebGL backend implements, and a shader kind is a closed enum
// so "which program does this draw use" is exhaustive in every backend.

use std::derive {derive_copy, derive_clone, derive_debug}
use std::map {HashMap, Map}
use std::list {}
use init::copy {Copy}
use init::clone {Clone}
use lib::command {
    Color, color_white, MeshHandle, mesh_handle, MaterialHandle, material_handle
}
use lib::mesh {MeshData}

// ── Shader kind ─────────────────────────────────────────────────────

/// Which program draws a material.
#[derive Copy Clone Debug]
pub type ShaderKind {
    shader_flat,
    shader_textured
}

/// A stable small integer per kind (also the backends' program index).
pub def shader_kind_code (k : ShaderKind) : I64 :=
    match k {
        shader_flat => 0,
        shader_textured => 1
    }

// ── Textures ────────────────────────────────────────────────────────

/// An opaque texture id. `texture_none` (id < 0) means "no texture".
#[derive Copy Clone Debug]
pub struct TextureHandle {
    id : I64
}

pub def texture_handle (i : I64) : TextureHandle := { id := i : TextureHandle }

pub def texture_handle_id (h : TextureHandle) : I64 := h.id

pub def texture_none : TextureHandle := { id := I64.sub 0 1 : TextureHandle }

pub def texture_is_none (h : TextureHandle) : Bool := I64.lt h.id 0

#[derive Copy Clone Debug]
pub type TextureFilter {
    filter_nearest,
    filter_linear
}

#[derive Copy Clone Debug]
pub type TextureWrap {
    wrap_repeat,
    wrap_clamp
}

/// Where a texture comes from and how it is sampled. Loading is the
/// backend's job (in a browser it is asynchronous).
#[derive Copy Clone Debug]
pub struct TextureDesc {
    url : String,
    filter : TextureFilter,
    wrap : TextureWrap
}

pub def texture_desc (url : String) (filter : TextureFilter) (wrap : TextureWrap) : TextureDesc :=
    { url := url, filter := filter, wrap := wrap : TextureDesc }

/// A linearly filtered, edge-clamped texture -- the usual choice for art.
pub def texture_from_url (url : String) : TextureDesc := texture_desc url filter_linear wrap_clamp

pub def texture_url (t : TextureDesc) : String := t.url

pub def texture_filter (t : TextureDesc) : TextureFilter := t.filter

pub def texture_wrap (t : TextureDesc) : TextureWrap := t.wrap

pub def texture_is_linear (t : TextureDesc) : Bool :=
    match t.filter {
        filter_linear => true,
        filter_nearest => false
    }

pub def texture_repeats (t : TextureDesc) : Bool :=
    match t.wrap {
        wrap_repeat => true,
        wrap_clamp => false
    }

// ── Materials ───────────────────────────────────────────────────────

/// How a mesh is shaded: the program, a tint multiplied into the output, and
/// (for `shader_textured`) the texture sampled.
#[derive Copy Clone Debug]
pub struct Material {
    shader : ShaderKind,
    tint : Color,
    texture : TextureHandle
}

/// A single flat colour.
pub def material_flat (tint : Color) : Material :=
    { shader := shader_flat, tint := tint, texture := texture_none : Material }

/// A texture multiplied by `tint` (white leaves the texture as authored).
pub def material_textured (texture : TextureHandle) (tint : Color) : Material :=
    { shader := shader_textured, tint := tint, texture := texture : Material }

/// What a draw falls back to when its material id is unknown: flat white, so
/// the mesh is still visible and the mistake is obvious.
pub def material_default : Material := material_flat color_white

pub def material_shader (m : Material) : ShaderKind := m.shader

pub def material_tint (m : Material) : Color := m.tint

pub def material_texture (m : Material) : TextureHandle := m.texture

// ── Assets ──────────────────────────────────────────────────────────

/// The handle -> data tables. Ids are handed out densely from 1 (0 is never
/// a valid handle), and the `*_ids` lists keep insertion order so a backend
/// uploads deterministically. `Copy` is the hand-written identity: every
/// field is an immutable, shared structure.
pub struct Assets {
    meshes : HashMap I64 MeshData,
    materials : HashMap I64 Material,
    textures : HashMap I64 TextureDesc,
    mesh_ids : List I64,
    texture_ids : List I64,
    next_mesh : I64,
    next_material : I64,
    next_texture : I64
}

pub instance Copy Assets {
    def copy (a : Assets) : Pair Assets Assets := Pair.pair a a
}

pub def assets_empty : Assets :=
    { meshes := Map.empty,
      materials := Map.empty,
      textures := Map.empty,
      mesh_ids := [],
      texture_ids := [],
      next_mesh := 1,
      next_material := 1,
      next_texture := 1
      : Assets }

/// `Assets` after an insertion, with the handle that now names the entry.
pub struct MeshAdded {
    assets : Assets,
    handle : MeshHandle
}

pub instance Copy MeshAdded {
    def copy (x : MeshAdded) : Pair MeshAdded MeshAdded := Pair.pair x x
}

pub struct MaterialAdded {
    assets : Assets,
    handle : MaterialHandle
}

pub instance Copy MaterialAdded {
    def copy (x : MaterialAdded) : Pair MaterialAdded MaterialAdded := Pair.pair x x
}

pub struct TextureAdded {
    assets : Assets,
    handle : TextureHandle
}

pub instance Copy TextureAdded {
    def copy (x : TextureAdded) : Pair TextureAdded TextureAdded := Pair.pair x x
}

def mesh_added (a : Assets) (h : MeshHandle) : MeshAdded := { assets := a, handle := h : MeshAdded }

def material_added (a : Assets) (h : MaterialHandle) : MaterialAdded :=
    { assets := a, handle := h : MaterialAdded }

def texture_added (a : Assets) (h : TextureHandle) : TextureAdded :=
    { assets := a, handle := h : TextureAdded }

pub def assets_add_mesh (a : Assets) (m : MeshData) : MeshAdded :=
    let id : I64 := a.next_mesh in
    let a2 : Assets :=
        { a with meshes := Map.insert id m a.meshes,
                 mesh_ids := List.append a.mesh_ids [id],
                 next_mesh := I64.add id 1 } in
    mesh_added a2 (mesh_handle id)

pub def assets_add_material (a : Assets) (m : Material) : MaterialAdded :=
    let id : I64 := a.next_material in
    let a2 : Assets :=
        { a with materials := Map.insert id m a.materials,
                 next_material := I64.add id 1 } in
    material_added a2 (material_handle id)

pub def assets_add_texture (a : Assets) (t : TextureDesc) : TextureAdded :=
    let id : I64 := a.next_texture in
    let a2 : Assets :=
        { a with textures := Map.insert id t a.textures,
                 texture_ids := List.append a.texture_ids [id],
                 next_texture := I64.add id 1 } in
    texture_added a2 (texture_handle id)

pub def assets_mesh (a : Assets) (id : I64) : Option MeshData := Map.lookup id a.meshes

pub def assets_material (a : Assets) (id : I64) : Option Material := Map.lookup id a.materials

pub def assets_texture (a : Assets) (id : I64) : Option TextureDesc := Map.lookup id a.textures

/// Every mesh id, in insertion order.
pub def assets_mesh_ids (a : Assets) : List I64 := a.mesh_ids

/// Every texture id, in insertion order.
pub def assets_texture_ids (a : Assets) : List I64 := a.texture_ids

pub def assets_mesh_count (a : Assets) : I64 := List.length a.mesh_ids

pub def assets_material_count (a : Assets) : I64 := I64.sub a.next_material 1

pub def assets_texture_count (a : Assets) : I64 := List.length a.texture_ids

/// The material for `id`, or `material_default` when the id is unknown.
pub def assets_material_or_default (a : Assets) (id : I64) : Material :=
    match Map.lookup id a.materials {
        Option.some m => m,
        Option.none => material_default
    }

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_empty_assets_have_nothing : Bool :=
    I64.beq (assets_mesh_count assets_empty) 0
        && I64.beq (assets_material_count assets_empty) 0
        && I64.beq (assets_texture_count assets_empty) 0

#[test]
def test_shader_kind_codes_differ : Bool :=
    I64.beq (shader_kind_code shader_flat) 0 && I64.beq (shader_kind_code shader_textured) 1

#[test]
def test_material_flat_has_no_texture : Bool :=
    texture_is_none (material_texture (material_flat color_white))

#[test]
def test_material_textured_keeps_its_texture : Bool :=
    let m : Material := material_textured (texture_handle 4) color_white in
    I64.beq (texture_handle_id (material_texture m)) 4
        && I64.beq (shader_kind_code (material_shader m)) 1

#[test]
def test_texture_from_url_is_linear_and_clamped : Bool :=
    let t : TextureDesc := texture_from_url "board.png" in
    texture_is_linear t && Bool.not (texture_repeats t) && String.beq (texture_url t) "board.png"

#[test]
def test_material_handles_are_dense_from_one : Bool :=
    let a : MaterialAdded := assets_add_material assets_empty (material_flat color_white) in
    let b : MaterialAdded := assets_add_material a.assets (material_flat color_white) in
    let ha : MaterialHandle := a.handle in
    let hb : MaterialHandle := b.handle in
    I64.beq ha.id 1 && I64.beq hb.id 2 && I64.beq (assets_material_count b.assets) 2

#[test]
def test_unknown_material_falls_back_to_default : Bool :=
    I64.beq (shader_kind_code (material_shader (assets_material_or_default assets_empty 99))) 0

#[test]
def test_texture_ids_keep_insertion_order : Bool :=
    let a : TextureAdded := assets_add_texture assets_empty (texture_from_url "a.png") in
    let b : TextureAdded := assets_add_texture a.assets (texture_from_url "b.png") in
    match List.get 1 (assets_texture_ids b.assets) {
        Option.some id =>
            match assets_texture b.assets id {
                Option.some t => String.beq (texture_url t) "b.png",
                Option.none => false
            },
        Option.none => false
    }
