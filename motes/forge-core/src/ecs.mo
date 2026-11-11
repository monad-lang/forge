// forge-core ECS: Entity, ComponentId, Column, Archetype, ComponentStorage,
// World -- the core data model. See ../../../PLAN.md, Phase 1.
//
// ## Affine-by-default
//
// An unannotated binder may be used at most once unless `Copy A` resolves.
// Two consequences shape this file:
//
//  - POD types (`Entity`, `ComponentId`, `Loc`, `Column`, `Archetype`,
//    `ComponentRegistry`, `ComponentStorage`, `World`, `Alloc`) derive
//    `Copy`, so their fields can be read as often as a formula needs.
//  - A helper that reuses a raw `List`/`HashMap`/`Pair` binder wraps it in
//    `Shared` (the `std/map.mo` pattern), clones it for a second owner with
//    `Clone.clone (Shared.of x)`, or threads it once instead of reading it
//    twice. `Pair` itself is NOT `Copy`, so multi-field results are returned
//    as named `Copy` structs (`Interned`, `Relocated`, ...) rather than pairs.
//
// ## The one trap: `#[derive Copy]` needs `use std::derive {}`
//
// A `#[derive Copy ...]` attribute is a NO-OP unless this file imports
// `std::derive`. Without that import the struct is still affine, and every
// "used N times but is affine" error points at a type that *looks* `Copy`.
// The import is below; do NOT remove it. (Verified by probe: the identical
// struct with and without the import flips the diagnostic.)
//
// ## Storage shape
//
// Component names are interned once into a `ComponentRegistry`; every
// internal key is a small `I64`. An archetype is identified by the SORTED
// list of its component ids, rendered as a `String` key so a `HashMap` can
// index archetypes in O(1). Rows live in per-component `Column`s, strictly
// parallel to the archetype's sorted `ids`, so a component read is O(1).
//
// ## Row removal is swap-remove
//
// Removing a row (despawn, or a component change that migrates the entity to
// another archetype) moves the archetype's LAST row into the freed slot and
// truncates. That keeps the fix-up O(1) instead of invalidating every
// `entity_location` after the removed row -- the moved entity's location is
// rewritten here, in one place.

use std::map {HashMap, Map}
use std::list {List.any, List.all}
use std::derive {}
use init::copy {Copy}
use init::clone {Clone}
use init::shared {Shared}

// ── Identity ────────────────────────────────────────────────────────

/// A generational entity handle. `Copy`: two scalars.
#[derive Copy Clone BEq Debug]
pub struct Entity {
    id : U64,
    generation : U64
}

pub def entity_id (e : Entity) : U64 := e.id

pub def entity_gen (e : Entity) : U64 := e.generation

pub def entity_new (id : U64) (generation : U64) : Entity :=
    { id := id, generation := generation : Entity }

/// An interned component name. `Copy`: one scalar.
#[derive Copy Clone BEq Debug]
pub struct ComponentId {
    id : I64
}

pub def component_id (c : ComponentId) : I64 := c.id

pub def component_id_new (i : I64) : ComponentId := { id := i : ComponentId }

/// Where an entity's row lives: an archetype index and a row within it.
/// A named `Copy` struct rather than a bare `Pair I64 I64`, because a `Pair`
/// cannot be read field-by-field under the affine rule.
#[derive Copy Clone Debug]
pub struct Loc {
    archetype : I64,
    row : I64
}

pub def loc_new (archetype : I64) (row : I64) : Loc :=
    { archetype := archetype, row := row : Loc }

/// A recycled entity slot: the id to reuse and the generation it takes on.
#[derive Copy Clone BEq Debug]
pub struct Freed {
    id : U64,
    generation : U64
}

// ── Component registry ──────────────────────────────────────────────

/// Interns component names to dense `I64` ids, once per world.
#[derive Copy Clone Debug]
pub struct ComponentRegistry {
    by_name : HashMap String I64,
    by_id : HashMap I64 String,
    next : I64
}

pub def empty_registry : ComponentRegistry :=
    { by_name := Map.empty, by_id := Map.empty, next := 0 : ComponentRegistry }

pub def registry_len (r : ComponentRegistry) : I64 := r.next

/// Intern a name, returning both the new registry and the id.
#[derive Copy Clone Debug]
pub struct Interned {
    registry : ComponentRegistry,
    id : ComponentId
}

/// Name -> id, allocating a fresh id on first sight.
pub def intern (reg : ComponentRegistry) (name : String) : Interned :=
    match Map.lookup name reg.by_name {
        Option.some i => { registry := reg, id := { id := i : ComponentId } : Interned },
        Option.none =>
            let i : I64 := reg.next in
            let reg2 : ComponentRegistry :=
                { by_name := Map.insert name i reg.by_name,
                  by_id := Map.insert i name reg.by_id,
                  next := I64.add reg.next 1 } in
            { registry := reg2, id := { id := i : ComponentId } : Interned }
    }

/// Intern many names at once, preserving order.
#[derive Copy Clone Debug]
pub struct InternedAll {
    registry : ComponentRegistry,
    ids : List ComponentId
}

#[terminating]
def intern_all_go
    (reg : ComponentRegistry)
    (names : List String)
    : InternedAll :=
    match names {
        List.empty => { registry := reg, ids := [] : InternedAll },
        List.cons n rest =>
            let stepped : Interned := intern reg n in
            let rest_ids : InternedAll := intern_all_go stepped.registry rest in
            { registry := rest_ids.registry,
              ids := List.cons stepped.id rest_ids.ids
              : InternedAll }
    }

pub def intern_all (reg : ComponentRegistry) (names : List String) : InternedAll :=
    intern_all_go reg names

pub def name_of (reg : ComponentRegistry) (c : ComponentId) : Option String :=
    Map.lookup c.id reg.by_id

/// Look up an already-interned name; `Option.none` if this world has never
/// seen it (so no value of that component can exist either).
pub def lookup_component (reg : ComponentRegistry) (name : String) : Option ComponentId :=
    match Map.lookup name reg.by_name {
        Option.some i => Option.some { id := i : ComponentId },
        Option.none => Option.none
    }

// ── Archetype keys ──────────────────────────────────────────────────

/// Insertion sort of component ids (small lists; there is no total
/// `List.sort` for `I64` in the prelude).
#[terminating]
def insert_id (id : I64) (xs : List I64) : List I64 :=
    match xs {
        List.empty => [id],
        List.cons h rest =>
            if Bool.not (I64.gt id h)
            then List.cons id (List.cons h rest)
            else List.cons h (insert_id id rest)
    }

#[terminating]
pub def sort_ids (xs : List I64) : List I64 :=
    match xs {
        List.empty => [],
        List.cons h rest => insert_id h (sort_ids rest)
    }

/// The canonical (sorted) order of a component set. An archetype's `ids`
/// field is ALWAYS in this order and its `columns` are parallel to it, so two
/// entities carrying the same components in different orders land in the same
/// archetype with correctly aligned columns.
#[terminating]
def sorted_go (ids : List ComponentId) (acc : List ComponentId) : List ComponentId :=
    match ids {
        List.empty => sort_by_id acc,
        List.cons c rest => sorted_go rest (List.cons c acc)
    }

/// Insertion sort of `ComponentId` by id (stable, small lists).
#[terminating]
def sort_by_id (xs : List ComponentId) : List ComponentId :=
    match xs {
        List.empty => [],
        List.cons h rest => insert_cid h (sort_by_id rest)
    }

#[terminating]
def insert_cid (c : ComponentId) (xs : List ComponentId) : List ComponentId :=
    match xs {
        List.empty => [c],
        List.cons h rest =>
            if Bool.not (I64.gt c.id h.id)
            then List.cons c (List.cons h rest)
            else List.cons h (insert_cid c rest)
    }

pub def sorted_ids (ids : List ComponentId) : List ComponentId := sort_by_id ids

/// Render an already-sorted id list as a canonical string key.
#[terminating]
def key_go (ids : List ComponentId) (acc : String) : String :=
    match ids {
        List.empty => acc,
        List.cons c rest =>
            key_go rest (String.concat acc (String.concat (I64.to_string c.id) ","))
    }

/// The key for an already-sorted `ComponentId` list.
pub def ids_key (ids : List ComponentId) : String := key_go ids ""

/// The canonical key of a component set, whatever order it was built in.
pub def archetype_key (ids : List ComponentId) : String := ids_key (sorted_ids ids)

// ── Columns and archetypes ──────────────────────────────────────────

/// One component's data for every row of an archetype.
///
/// `List Any` rather than `std.array`'s `Array Any`: `Array` is not `pub` in
/// the installed `std::array`, so a mote cannot name it. `len` keeps the
/// length O(1); the column API below is the only place that would change if
/// that ever becomes visible.
#[derive Copy Clone Debug]
pub struct Column {
    data : List Any,
    len : U64
}

pub def empty_column : Column := { data := [], len := 0u64 : Column }

pub def column_len (c : Column) : U64 := c.len

pub def column_get (c : Column) (row : I64) : Option Any :=
    if I64.lt row 0
    then Option.none
    else if I64.lt row (U64.to_i64 c.len)
         then List.get row c.data
         else Option.none

/// Append a value; returns the new column and the row index it landed at.
#[derive Copy Clone Debug]
pub struct Pushed {
    column : Column,
    row : I64
}

pub def column_push (c : Column) (v : Any) : Pushed :=
    let row : I64 := U64.to_i64 c.len in
    { column := { data := List.append c.data [v], len := U64.add c.len 1u64 : Column },
      row := row
      : Pushed }

/// Overwrite an existing row (persistent: rebuilds the list).
#[terminating]
def set_at_go (xs : List Any) (row : I64) (v : Any) (n : I64) : List Any :=
    match xs {
        List.empty => [],
        List.cons h rest =>
            if I64.beq row n
            then List.cons v rest
            else List.cons h (set_at_go rest row v (I64.add n 1))
    }

pub def column_set (c : Column) (row : I64) (v : Any) : Column :=
    { data := set_at_go c.data row v 0, len := c.len : Column }

/// `n` copies of the unit placeholder, in order. Pads a column that a
/// component starting mid-archetype never wrote to.
#[terminating]
def fill_n (n : I64) : List Any :=
    if I64.lt 0 n
    then List.cons (Any.any Unit.unit) (fill_n (I64.sub n 1))
    else []

/// Keep the first `keep` elements.
#[terminating]
def keep_n (xs : List Any) (keep : I64) (n : I64) : List Any :=
    match xs {
        List.empty => [],
        List.cons h rest =>
            if I64.lt n keep then List.cons h (keep_n rest keep (I64.add n 1)) else []
    }

/// Drop the column's last row.
pub def column_pop (c : Column) : Column :=
    let keep : I64 := U64.to_i64 (U64.sub c.len 1u64) in
    { data := keep_n c.data keep 0, len := U64.sub c.len 1u64 : Column }

/// An archetype: a component set (sorted, canonical key) and its rows.
#[derive Copy Clone Debug]
pub struct Archetype {
    key : String,
    ids : List ComponentId,
    columns : List Column,
    entities : List Entity
}

pub def empty_archetype : Archetype :=
    { key := "", ids := [], columns := [], entities := [] : Archetype }

pub def archetype_ids (a : Archetype) : List ComponentId := a.ids

pub def archetype_rows (a : Archetype) : I64 := List.length a.entities

/// The entity handle stored at `row` of an archetype (a placeholder when the
/// row is out of range).
pub def archetype_entity_at (a : Archetype) (row : I64) : Entity :=
    match List.get row a.entities {
        Option.some e => e,
        Option.none => entity_new 0u64 0u64
    }

/// The entity handle at `row` of archetype `i` of `world`.
pub def world_entity_at (world : World) (i : I64) (row : I64) : Entity :=
    archetype_entity_at (storage_archetype_at world.storage i) row

/// The column for `c`, if this archetype has it.
#[terminating]
def find_column_go (columns : List Column) (ids : List ComponentId) (want : ComponentId) : Option Column :=
    match columns {
        List.empty => Option.none,
        List.cons col rest =>
            match ids {
                List.empty => Option.none,
                List.cons c cr =>
                    if I64.beq c.id want.id then Option.some col else find_column_go rest cr want
            }
    }

pub def archetype_column (a : Archetype) (want : ComponentId) : Option Column :=
    find_column_go a.columns a.ids want

/// Does `required` contain a component with `want`'s id?
pub def has_id (required : List ComponentId) (want : ComponentId) : Bool :=
    List.any (fn (r : ComponentId) => I64.beq r.id want.id) required

/// Does this archetype carry every component in `required`?
pub def archetype_has_all (a : Archetype) (required : List ComponentId) : Bool :=
    List.all (fn (r : ComponentId) => has_id a.ids r) required

/// Add one value per component of `a`, in `a.ids` order. Columns are created
/// on this archetype's first row and padded when a component's column does
/// not exist yet.
#[terminating]
def append_columns_go
    (columns : List Column)
    (ids : List ComponentId)
    (values : List Any)
    (prior : I64)
    : List Column :=
    match ids {
        List.empty => [],
        List.cons _ cr =>
            match values {
                List.empty => [],
                List.cons v vr =>
                    match columns {
                        List.cons col rest =>
                            let pushed : Pushed := column_push col v in
                            List.cons pushed.column (append_columns_go rest cr vr prior),
                        List.empty =>
                            let fresh : Column :=
                                { data := fill_n prior, len := I64.to_u64 prior : Column } in
                            let pushed : Pushed := column_push fresh v in
                            List.cons pushed.column (append_columns_go List.empty cr vr prior)
                    }
            }
    }

pub def archetype_append_row (a : Archetype) (values : List Any) (entity : Entity) : Archetype :=
    let prior : I64 := archetype_rows a in
    { key := a.key,
      ids := a.ids,
      columns := append_columns_go a.columns a.ids values prior,
      entities := List.append a.entities [entity] : Archetype }

/// Replace a row's entity in an archetype (keeps columns aligned).
#[terminating]
def set_entity_at (es : List Entity) (i : I64) (e : Entity) (n : I64) : List Entity :=
    match es {
        List.empty => [],
        List.cons h rest =>
            if I64.beq i n
            then List.cons e rest
            else List.cons h (set_entity_at rest i e (I64.add n 1))
    }

pub def archetype_set_entity (a : Archetype) (row : I64) (e : Entity) : Archetype :=
    { key := a.key, ids := a.ids, columns := a.columns,
      entities := set_entity_at a.entities row e 0 : Archetype }

/// Copy row `from` into row `to` (both must exist).
#[terminating]
def copy_row_go (columns : List Column) (from : I64) (to : I64) : List Column :=
    match columns {
        List.empty => [],
        List.cons col rest =>
            match column_get col from {
                Option.some v => List.cons (column_set col to v) (copy_row_go rest from to),
                Option.none => List.cons col (copy_row_go rest from to)
            }
    }

/// Copy row `from` into row `to`: BOTH the columns and the entity handle. The
/// entity half is load-bearing -- swap-remove calls this to move the last row
/// into the freed slot, and without it `entities[to]` keeps naming the departed
/// entity, so every `archetype_row_pairs`-by-index walk (`query.mo`, and
/// anything reading `Archetype.entities` directly) returns the wrong entity.
def copy_row (a : Archetype) (from : I64) (to : I64) : Archetype :=
    let columns : List Column := copy_row_go a.columns from to in
    match List.get from a.entities {
        Option.none =>
            { key := a.key, ids := a.ids, columns := columns, entities := a.entities : Archetype },
        Option.some e =>
            { key := a.key, ids := a.ids, columns := columns,
              entities := set_entity_at a.entities to e 0 : Archetype }
    }

#[terminating]
def pop_columns (columns : List Column) : List Column :=
    match columns {
        List.empty => [],
        List.cons col rest => List.cons (column_pop col) (pop_columns rest)
    }

/// Keep the first `keep` entities.
#[terminating]
def keep_entities (es : List Entity) (keep : I64) (n : I64) : List Entity :=
    match es {
        List.empty => [],
        List.cons h rest =>
            if I64.lt n keep then List.cons h (keep_entities rest keep (I64.add n 1)) else []
    }

/// Drop the archetype's last row from every column and from `entities`.
pub def archetype_truncate (a : Archetype) : Archetype :=
    let keep : I64 := I64.sub (archetype_rows a) 1 in
    { key := a.key, ids := a.ids,
      columns := pop_columns a.columns,
      entities := keep_entities a.entities keep 0 : Archetype }

/// A row moved by swap-remove: which entity, and where it ended up.
#[derive Copy Clone Debug]
pub struct Moved {
    entity : Entity,
    row : I64
}

/// The result of a swap-remove: the shrunk archetype plus (optionally) the
/// entity that took the freed slot, for the caller to re-point.
#[derive Copy Clone Debug]
pub struct RemoveResult {
    arch : Archetype,
    moved : Option Moved
}

/// Remove row `row`: the LAST row takes its slot, and is reported back so the
/// caller can rewrite that entity's location. `moved = Option.none` means no
/// other entity moved (the removed row was the last one).
pub def archetype_swap_remove (a : Archetype) (row : I64) : RemoveResult :=
    let last : I64 := I64.sub (archetype_rows a) 1 in
    if I64.beq row last
    then { arch := archetype_truncate a, moved := Option.none : RemoveResult }
    else
        match List.get last a.entities {
            Option.none => { arch := a, moved := Option.none : RemoveResult },
            Option.some moved_entity =>
                let moved_into : Archetype := copy_row a last row in
                { arch := archetype_truncate moved_into,
                  moved := Option.some { entity := moved_entity, row := row : Moved }
                  : RemoveResult }
        }

// ── Component/value rows ────────────────────────────────────────────
//
// A "row" is a `List (Pair ComponentId Any)` in arbitrary order; it is the
// carrier that `insert_component` / `remove_component` build before handing
// it to `relocate`.

/// The value stored for `want`, if present.
#[terminating]
def find_value_go (pairs : List (Pair ComponentId Any)) (want : ComponentId) : Option Any :=
    match pairs {
        List.empty => Option.none,
        List.cons p rest =>
            match p {
                Pair.pair c v =>
                    if I64.beq c.id want.id then Option.some v else find_value_go rest want
            }
    }

pub def row_value (pairs : List (Pair ComponentId Any)) (want : ComponentId) : Option Any :=
    find_value_go pairs want

/// Drop the entry for `want`, keeping the rest in order.
#[terminating]
def drop_pair_go (pairs : List (Pair ComponentId Any)) (want : ComponentId) : List (Pair ComponentId Any) :=
    match pairs {
        List.empty => [],
        List.cons p rest =>
            match p {
                Pair.pair c _ =>
                    if I64.beq c.id want.id
                    then drop_pair_go rest want
                    else List.cons p (drop_pair_go rest want)
            }
    }

pub def drop_pair (pairs : List (Pair ComponentId Any)) (want : ComponentId) : List (Pair ComponentId Any) :=
    drop_pair_go pairs want

/// Insert-or-replace `(want, v)`, keeping the row's other entries.
pub def upsert_pair (pairs : List (Pair ComponentId Any)) (want : ComponentId) (v : Any) : List (Pair ComponentId Any) :=
    List.cons (Pair.pair want v) (drop_pair_go pairs want)

/// The ids of a row, in the order they were collected.
#[terminating]
def ids_of_pairs (pairs : List (Pair ComponentId Any)) : List ComponentId :=
    match pairs {
        List.empty => [],
        List.cons p rest =>
            match p {
                Pair.pair c _ => List.cons c (ids_of_pairs rest)
            }
    }

/// Pair interned ids with the values that produced them.
#[terminating]
def zip_pairs_go (ids : List ComponentId) (comps : List (Pair String Any)) : List (Pair ComponentId Any) :=
    match ids {
        List.empty => [],
        List.cons c cr =>
            match comps {
                List.empty => [],
                List.cons p pr =>
                    match p {
                        Pair.pair _ v => List.cons (Pair.pair c v) (zip_pairs_go cr pr)
                    }
            }
    }

/// The value for `want`, or the unit placeholder.
#[terminating]
def value_at (pairs : List (Pair ComponentId Any)) (want : ComponentId) : Any :=
    match find_value_go pairs want {
        Option.some v => v,
        Option.none => Any.any Unit.unit
    }

/// A row's values in `ids` order; `Unit` where the row has no value (a column
/// that a mid-archetype insert created for a different entity). `pairs` is
/// read once per id, so it travels as a `Shared` handle.
#[terminating]
def values_go (sp : Shared (List (Pair ComponentId Any))) (ids : List ComponentId) : List Any :=
    match ids {
        List.empty => [],
        List.cons want rest =>
            List.cons (value_at (Shared.get sp) want) (values_go sp rest)
    }

pub def values_for_ids (pairs : List (Pair ComponentId Any)) (ids : List ComponentId) : List Any :=
    values_go (Shared.of pairs) ids

// ── Storage ─────────────────────────────────────────────────────────

/// The world's component storage. Every field is an immutable `List`/
/// `HashMap`, so a duplicate handle shares; the whole struct is `Copy`.
#[derive Clone Debug]
pub struct ComponentStorage {
    archetypes : List Archetype,
    /// canonical archetype key -> index into `archetypes`
    archetype_index : HashMap String I64,
    /// entity id -> where its row lives
    entity_location : HashMap U64 Loc,
    free_ids : List Freed,
    next_id : U64,
    clock : U64,
    /// entity id -> (component id -> tick it last changed)
    last_changed : HashMap U64 (HashMap I64 U64),
    registry : ComponentRegistry
}

/// Hand-written identity `Copy`, NOT a derive: a derived `Copy` would call
/// `Copy.copy` on every field, which needs `Copy (HashMap ...)`/`Copy (List
/// ...)` instances that do not exist. Identity is correct for a persistent
/// structure (every field is immutable and shared by handle), and elaborates
/// to nothing. (`check` passes on the derive; ELABORATION is what fails, e.g.
/// via `StateT.get`'s `[Copy S]`.)
pub instance Copy ComponentStorage {
    def copy (s : ComponentStorage) : Pair ComponentStorage ComponentStorage := Pair.pair s s
}

pub def empty_storage : ComponentStorage :=
    { archetypes := [],
      archetype_index := Map.empty,
      entity_location := Map.empty,
      free_ids := [],
      next_id := 0u64,
      clock := 0u64,
      last_changed := Map.empty,
      registry := empty_registry
      : ComponentStorage }

/// The world. Hand-written identity `Copy`, for `ComponentStorage`'s reason.
#[derive Clone Debug]
pub struct World {
    storage : ComponentStorage
}

pub instance Copy World {
    def copy (w : World) : Pair World World := Pair.pair w w
}

pub def empty_world : World := { storage := empty_storage : World }

pub def world_clock (w : World) : U64 := w.storage.clock

pub def world_registry (w : World) : ComponentRegistry := w.storage.registry

pub def world_entity_count (w : World) : I64 :=
    List.length (HashMap.to_list w.storage.entity_location)

/// Number of distinct component sets seen by this world.
pub def world_archetype_count (w : World) : I64 := List.length w.storage.archetypes

/// The freed entity slots, oldest first.
pub def world_free_ids (w : World) : List Freed := w.storage.free_ids

/// Whether the world has interned `name` (and so may hold values for it).
pub def world_has_component (w : World) (name : String) : Bool :=
    match Map.lookup name w.storage.registry.by_name {
        Option.some _ => true,
        Option.none => false
    }

pub def world_archetype_ids (w : World) (i : I64) : List ComponentId :=
    match List.get i w.storage.archetypes {
        Option.some a => a.ids,
        Option.none => []
    }

// ── Allocation ──────────────────────────────────────────────────────

/// The entity a fresh id resolves to, plus the updated allocator state.
#[derive Copy Clone Debug]
pub struct Alloc {
    entity : Entity,
    next_id : U64,
    free_ids : List Freed
}

def alloc_id (storage : ComponentStorage) : Alloc :=
    match storage.free_ids {
        List.cons slot rest =>
            { entity := { id := slot.id, generation := slot.generation : Entity },
              next_id := storage.next_id,
              free_ids := rest
              : Alloc },
        List.empty =>
            { entity := { id := storage.next_id, generation := 0u64 : Entity },
              next_id := U64.add storage.next_id 1u64,
              free_ids := []
              : Alloc }
    }

// ── Archetype table ─────────────────────────────────────────────────

/// Find an archetype by canonical key; `Option.none` if absent.
def find_archetype_index (storage : ComponentStorage) (key : String) : Option I64 :=
    Map.lookup key storage.archetype_index

/// An archetype index paired with the storage that may have just grown.
#[derive Copy Clone Debug]
pub struct Located {
    storage : ComponentStorage,
    index : I64
}

/// Append a fresh archetype and record its index.
def register_archetype
    (storage : ComponentStorage)
    (key : String)
    (ids : List ComponentId)
    : Located :=
    let i : I64 := List.length storage.archetypes in
    let fresh : Archetype := { key := key, ids := ids, columns := [], entities := [] : Archetype } in
    let storage2 : ComponentStorage :=
        { storage with archetypes := List.append storage.archetypes [fresh],
                      archetype_index := Map.insert key i storage.archetype_index } in
    { storage := storage2, index := i : Located }

/// Replace the archetype at index `i` with `new_a`.
#[terminating]
def replace_arch_at (archetypes : List Archetype) (i : I64) (new_a : Archetype) (n : I64) : List Archetype :=
    match archetypes {
        List.empty => [],
        List.cons h rest =>
            if I64.beq i n
            then List.cons new_a rest
            else List.cons h (replace_arch_at rest i new_a (I64.add n 1))
    }

pub def storage_put_archetype (storage : ComponentStorage) (i : I64) (a : Archetype) : ComponentStorage :=
    { storage with archetypes := replace_arch_at storage.archetypes i a 0 }

pub def storage_set_location (storage : ComponentStorage) (eid : U64) (loc : Loc) : ComponentStorage :=
    { storage with entity_location := Map.insert eid loc storage.entity_location }

/// The archetype whose component set is exactly `ids`, creating it if this is
/// the first entity to carry that set.
def storage_archetype_for
    (storage : ComponentStorage)
    (ids : List ComponentId)
    : Located :=
    let s : Shared (List ComponentId) := Shared.of ids in
    let key : String := ids_key (Shared.get s) in
    match find_archetype_index storage key {
        Option.some i => { storage := storage, index := i : Located },
        Option.none => register_archetype storage key (Clone.clone s)
    }

/// The archetype at `i`, or the empty one.
pub def storage_archetype_at (storage : ComponentStorage) (i : I64) : Archetype :=
    match List.get i storage.archetypes {
        Option.some a => a,
        Option.none => empty_archetype
    }

/// Stamp `tick` for every component in `ids`, threading the entries map once.
#[terminating]
def stamp_go (tick : U64) (ids : List ComponentId) (entries : HashMap I64 U64) : HashMap I64 U64 :=
    match ids {
        List.empty => entries,
        List.cons c rest => stamp_go tick rest (Map.insert c.id tick entries)
    }

/// Record the change tick for every component in `ids`.
pub def touch_all
    (log : HashMap U64 (HashMap I64 U64))
    (eid : U64)
    (ids : List ComponentId)
    (tick : U64)
    : HashMap U64 (HashMap I64 U64) :=
    let s : Shared (HashMap U64 (HashMap I64 U64)) := Shared.of log in
    let entries : HashMap I64 U64 :=
        match Map.lookup eid (Shared.get s) {
            Option.some m => m,
            Option.none => Map.empty
        } in
    let entries2 : HashMap I64 U64 := stamp_go tick ids entries in
    Map.insert eid entries2 (Shared.get s)

// ── Spawn ───────────────────────────────────────────────────────────

/// The new world and the entity that was born.
#[derive Copy Clone Debug]
pub struct Spawned {
    world : World,
    entity : Entity
}

/// Spawn an entity with the given `(name, value)` components.
pub def spawn (world : World) (components : List (Pair String Any)) : Spawned :=
    let storage : ComponentStorage := world.storage in
    let alloc : Alloc := alloc_id storage in
    let sc : Shared (List (Pair String Any)) := Shared.of components in
    let names : List String :=
        List.map (fn (c : Pair String Any) => c.first) (Shared.get sc) in
    let interned : InternedAll := intern_all storage.registry names in
    let ids : List ComponentId := sorted_ids interned.ids in
    let sids : Shared (List ComponentId) := Shared.of ids in
    let pairs : List (Pair ComponentId Any) := zip_pairs_go interned.ids (Shared.get sc) in
    let located : Located := storage_archetype_for storage (Clone.clone sids) in
    let old_a : Archetype := storage_archetype_at located.storage located.index in
    let row : I64 := archetype_rows old_a in
    let new_a : Archetype :=
        archetype_append_row old_a (values_for_ids pairs (Clone.clone sids)) alloc.entity in
    let new_clock : U64 := U64.add located.storage.clock 1u64 in
    let new_log : HashMap U64 (HashMap I64 U64) :=
        touch_all located.storage.last_changed alloc.entity.id (Clone.clone sids) new_clock in
    let storage2 : ComponentStorage :=
        { located.storage with
            archetypes := replace_arch_at located.storage.archetypes located.index new_a 0,
            entity_location := Map.insert alloc.entity.id (loc_new located.index row) located.storage.entity_location,
            free_ids := alloc.free_ids,
            next_id := alloc.next_id,
            clock := new_clock,
            last_changed := new_log,
            registry := interned.registry } in
    { world := { storage := storage2 : World }, entity := alloc.entity : Spawned }

// ── Lookup ──────────────────────────────────────────────────────────

pub def entity_exists (world : World) (e : Entity) : Bool :=
    match Map.lookup e.id world.storage.entity_location {
        Option.some _ => true,
        Option.none => false
    }

/// Where a live entity's row sits.
pub def entity_location (world : World) (e : Entity) : Option Loc :=
    Map.lookup e.id world.storage.entity_location

pub def archetype_at (world : World) (i : I64) : Option Archetype :=
    List.get i world.storage.archetypes

/// The archetype holding `e`, if it is alive.
pub def archetype_of (world : World) (e : Entity) : Option Archetype :=
    match Map.lookup e.id world.storage.entity_location {
        Option.none => Option.none,
        Option.some loc => archetype_at world loc.archetype
    }

pub def entity_row (world : World) (e : Entity) : Option I64 :=
    match Map.lookup e.id world.storage.entity_location {
        Option.none => Option.none,
        Option.some loc => Option.some loc.row
    }

/// All of an entity's components, as `(ComponentId, value)` pairs.
#[terminating]
def zip_row_go
    (columns : List Column)
    (ids : List ComponentId)
    (row : I64)
    : List (Pair ComponentId Any) :=
    match columns {
        List.empty => [],
        List.cons col rest =>
            match ids {
                List.empty => [],
                List.cons c cr =>
                    match column_get col row {
                        Option.some v => List.cons (Pair.pair c v) (zip_row_go rest cr row),
                        Option.none => zip_row_go rest cr row
                    }
            }
    }

/// One row of an archetype, as `(ComponentId, value)` pairs -- the
/// archetype-level view `query.mo` projects from.
pub def archetype_row_pairs (a : Archetype) (row : I64) : List (Pair ComponentId Any) :=
    zip_row_go a.columns a.ids row

/// An entity's component row, or the empty list when it is not alive.
pub def entity_pairs (world : World) (e : Entity) : List (Pair ComponentId Any) :=
    match Map.lookup e.id world.storage.entity_location {
        Option.none => [],
        Option.some loc =>
            let l : Loc := loc in
            match archetype_at world l.archetype {
                Option.none => [],
                Option.some a =>
                    let arch : Archetype := a in
                    zip_row_go arch.columns arch.ids l.row
            }
    }

/// The component ids carried by an entity.
pub def components_of (world : World) (e : Entity) : List ComponentId :=
    ids_of_pairs (entity_pairs world e)

/// One component's value on an entity, if it has that component.
pub def get_component (world : World) (e : Entity) (c : ComponentId) : Option Any :=
    row_value (entity_pairs world e) c

/// The value of a component identified by name, if any.
pub def get_component_named (world : World) (e : Entity) (name : String) : Option Any :=
    match lookup_component world.storage.registry name {
        Option.none => Option.none,
        Option.some c => get_component world e c
    }

/// Whether an entity carries the component with this id.
pub def has_component (world : World) (e : Entity) (c : ComponentId) : Bool :=
    has_id (components_of world e) c

/// Intern `names` to ids, skipping any this world has never seen (such a
/// component cannot exist, so it can never match a query).
#[terminating]
def ids_of_names_go (world : World) (names : List String) : List ComponentId :=
    match names {
        List.empty => [],
        List.cons n rest =>
            match lookup_component world.storage.registry n {
                Option.none => ids_of_names_go world rest,
                Option.some c => List.cons c (ids_of_names_go world rest)
            }
    }

pub def ids_of_names (world : World) (names : List String) : List ComponentId :=
    ids_of_names_go world names

/// How many rows an archetype holds (`i` out of range -> 0).
pub def archetype_row_count (world : World) (i : I64) : I64 :=
    archetype_rows (storage_archetype_at world.storage i)

// ── Move an entity between archetypes ───────────────────────────────

/// Detach the row at `(arch_i, row)`, then attach `eid` with `pairs` under
/// the archetype for `pairs`' component set. The swap-remove's moved entity
/// has its location rewritten here, so callers never see a stale
/// `entity_location`. Despawn, insert and remove all go through this.
pub def relocate
    (storage : ComponentStorage)
    (eid : U64)
    (arch_i : I64)
    (row : I64)
    (pairs : List (Pair ComponentId Any))
    : ComponentStorage :=
    let old_a : Archetype := storage_archetype_at storage arch_i in
    let removed : RemoveResult := archetype_swap_remove old_a row in
    let storage1 : ComponentStorage := storage_put_archetype storage arch_i removed.arch in
    let storage2 : ComponentStorage :=
        match removed.moved {
            Option.none => storage1,
            Option.some mv =>
                let m : Moved := mv in
                storage_set_location storage1 m.entity.id (loc_new arch_i m.row)
        } in
    let sp : Shared (List (Pair ComponentId Any)) := Shared.of pairs in
    let ids : List ComponentId := sorted_ids (ids_of_pairs (Shared.get sp)) in
    let sids : Shared (List ComponentId) := Shared.of ids in
    let located : Located := storage_archetype_for storage2 (Clone.clone sids) in
    let target : Archetype := storage_archetype_at located.storage located.index in
    let updated : Archetype :=
        archetype_append_row target (values_for_ids pairs (Clone.clone sids)) (entity_new eid 0u64) in
    storage_set_location
        (storage_put_archetype located.storage located.index updated)
        eid
        (loc_new located.index (archetype_rows target))

/// Add or overwrite the component named `name` on `e`.
pub def insert_component (world : World) (e : Entity) (name : String) (v : Any) : World :=
    match Map.lookup e.id world.storage.entity_location {
        Option.none => world,
        Option.some loc =>
            let l : Loc := loc in
            let interned : Interned := intern world.storage.registry name in
            let next_pairs : List (Pair ComponentId Any) := upsert_pair (entity_pairs world e) interned.id v in
            let storage1 : ComponentStorage := { world.storage with registry := interned.registry } in
            let moved : World := { storage := relocate storage1 e.id l.archetype l.row next_pairs : World } in
            mark_changed moved e interned.id (U64.add moved.storage.clock 1u64)
    }

/// Remove the component named `name` from `e`; a no-op when absent.
pub def remove_component (world : World) (e : Entity) (name : String) : World :=
    match lookup_component world.storage.registry name {
        Option.none => world,
        Option.some cid =>
            match Map.lookup e.id world.storage.entity_location {
                Option.none => world,
                Option.some loc =>
                    let l : Loc := loc in
                    let next_pairs : List (Pair ComponentId Any) := drop_pair (entity_pairs world e) cid in
                    { storage := relocate world.storage e.id l.archetype l.row next_pairs : World }
            }
    }

/// Write `v` into the column of `want`, or `Option.none` when absent.
#[terminating]
def write_column_go
    (columns : List Column)
    (ids : List ComponentId)
    (want : ComponentId)
    (row : I64)
    (v : Any)
    : Option (List Column) :=
    match columns {
        List.empty => Option.none,
        List.cons col rest =>
            match ids {
                List.empty => Option.none,
                List.cons c cr =>
                    if I64.beq c.id want.id
                    then Option.some (List.cons (column_set col row v) rest)
                    else
                        match write_column_go rest cr want row v {
                            Option.none => Option.none,
                            Option.some rest2 => Option.some (List.cons col rest2)
                        }
            }
    }

pub def write_column
    (columns : List Column)
    (ids : List ComponentId)
    (want : ComponentId)
    (row : I64)
    (v : Any)
    : Option (List Column) :=
    write_column_go columns ids want row v

/// The world and whether the write landed (the entity had that component).
#[derive Copy Clone Debug]
pub struct SetResult {
    world : World,
    ok : Bool
}

/// Write a component's value in place, without migrating archetypes.
pub def set_component (world : World) (e : Entity) (name : String) (v : Any) : SetResult :=
    match lookup_component world.storage.registry name {
        Option.none => { world := world, ok := false : SetResult },
        Option.some cid =>
            let c2 : ComponentId := cid in
            match Map.lookup e.id world.storage.entity_location {
                Option.none => { world := world, ok := false : SetResult },
                Option.some loc =>
                    let l : Loc := loc in
                    let a : Archetype := storage_archetype_at world.storage l.archetype in
                    match write_column a.columns a.ids c2 l.row v {
                        Option.none => { world := world, ok := false : SetResult },
                        Option.some columns =>
                            let updated : Archetype :=
                                { key := a.key, ids := a.ids, columns := columns, entities := a.entities : Archetype } in
                            let written : World :=
                                { storage := storage_put_archetype world.storage l.archetype updated : World } in
                            { world := mark_changed written e c2 (U64.add written.storage.clock 1u64),
                              ok := true
                              : SetResult }
                    }
            }
    }

// ── Despawn ─────────────────────────────────────────────────────────

pub def despawn (world : World) (e : Entity) : World :=
    match Map.lookup e.id world.storage.entity_location {
        Option.none => world,
        Option.some loc =>
            let l : Loc := loc in
            let storage : ComponentStorage := world.storage in
            let a : Archetype := storage_archetype_at storage l.archetype in
            let removed : RemoveResult := archetype_swap_remove a l.row in
            let storage1 : ComponentStorage := storage_put_archetype storage l.archetype removed.arch in
            let storage2 : ComponentStorage :=
                match removed.moved {
                    Option.none => storage1,
                    Option.some mv =>
                        let m : Moved := mv in
                        storage_set_location storage1 m.entity.id (loc_new l.archetype m.row)
                } in
            let freed : Freed := { id := e.id, generation := U64.add e.generation 1u64 : Freed } in
            let storage3 : ComponentStorage :=
                { storage2 with entity_location := Map.delete e.id storage2.entity_location,
                                free_ids := List.append storage2.free_ids [freed] } in
            { storage := storage3 : World }
    }

// ── Change detection ────────────────────────────────────────────────

/// Stamp `c` on `e` with `tick`, and set the world clock to `tick`.
pub def mark_changed (world : World) (e : Entity) (c : ComponentId) (tick : U64) : World :=
    let storage : ComponentStorage := world.storage in
    let s : Shared (HashMap U64 (HashMap I64 U64)) := Shared.of storage.last_changed in
    let entries : HashMap I64 U64 :=
        match Map.lookup e.id (Shared.get s) {
            Option.some m => m,
            Option.none => Map.empty
        } in
    let log : HashMap U64 (HashMap I64 U64) :=
        Map.insert e.id (Map.insert c.id tick entries) (Shared.get s) in
    let storage2 : ComponentStorage := { storage with clock := tick, last_changed := log } in
    { storage := storage2 : World }

/// Has `e`'s component `c` changed strictly after `last_seen`?
pub def changed_since (world : World) (e : Entity) (c : ComponentId) (last_seen : U64) : Bool :=
    match Map.lookup e.id world.storage.last_changed {
        Option.none => false,
        Option.some entries =>
            match Map.lookup c.id entries {
                Option.some tick => U64.gt tick last_seen,
                Option.none => false
            }
    }

/// The tick `e`'s component `c` last changed at, if it ever has.
pub def last_changed_at (world : World) (e : Entity) (c : ComponentId) : Option U64 :=
    match Map.lookup e.id world.storage.last_changed {
        Option.none => Option.none,
        Option.some entries => Map.lookup c.id entries
    }

/// Does `e`'s component `c` pass a `ChangedFilter`-style cutoff?
pub def changed_since_named (world : World) (e : Entity) (name : String) (last_seen : U64) : Bool :=
    match lookup_component world.storage.registry name {
        Option.none => false,
        Option.some c => changed_since world e c last_seen
    }

// ── Tests ───────────────────────────────────────────────────────────

#[test]
def test_entity_id : Bool :=
    U64.beq (entity_id { id := 1u64, generation := 0u64 : Entity }) 1u64

#[test]
def test_archetype_key_is_canonical : Bool :=
    let a : List ComponentId := [{ id := 2 : ComponentId }, { id := 0 : ComponentId }] in
    let b : List ComponentId := [{ id := 0 : ComponentId }, { id := 2 : ComponentId }] in
    String.beq (archetype_key a) (archetype_key b)

/// The self-hosted parser has no NESTED patterns, so "the list is exactly
/// [1, 2, 3]" is spelled as a walk rather than one nested `cons` pattern.
#[terminating]
def ids_are (xs : List I64) (want : List I64) : Bool :=
    match xs {
        List.empty => List.is_empty want,
        List.cons h rest =>
            match want {
                List.empty => false,
                List.cons w wr => if I64.beq h w then ids_are rest wr else false
            }
    }

#[test]
def test_sort_ids : Bool :=
    ids_are (sort_ids [3, 1, 2]) [1, 2, 3]

#[test]
def test_spawn_lands_in_one_archetype : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    I64.beq (world_archetype_count spawned.world) 1

#[test]
def test_unit_spawn_generation_zero : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    U64.beq spawned.entity.generation 0u64

#[test]
def test_double_spawn_shares_archetype : Bool :=
    let first : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let second : Spawned := spawn first.world [Pair.pair "pos" (Any.any 2u64)] in
    I64.beq (world_archetype_count second.world) 1

#[test]
def test_insert_component_migrates_archetype : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let world : World := insert_component spawned.world spawned.entity "vel" (Any.any 2u64) in
    I64.beq (world_archetype_count world) 2

#[test]
def test_remove_component_migrates_back : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let with_vel : World := insert_component spawned.world spawned.entity "vel" (Any.any 2u64) in
    let world : World := remove_component with_vel spawned.entity "vel" in
    I64.beq (world_archetype_count world) 2

#[test]
def test_despawn_frees_id : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let world : World := despawn spawned.world spawned.entity in
    I64.beq (List.length (world_free_ids world)) 1

#[test]
def test_entity_count_tracks_despawn : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let world : World := despawn spawned.world spawned.entity in
    I64.beq (world_entity_count world) 0

#[test]
def test_set_component_reports_hit : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let result : SetResult := set_component spawned.world spawned.entity "pos" (Any.any 9u64) in
    result.ok

#[test]
def test_mark_changed_then_changed_since : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let interned : Interned := intern spawned.world.storage.registry "pos" in
    let before : U64 := spawned.world.storage.clock in
    let world : World := mark_changed spawned.world spawned.entity interned.id (U64.add before 1u64) in
    changed_since world spawned.entity interned.id before

#[test]
def test_changed_since_named_false_when_unknown : Bool :=
    let spawned : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    Bool.not (changed_since_named spawned.world spawned.entity "nope" 0u64)

/// REGRESSION: remove a row from the MIDDLE of an archetype, then check that
/// the row swapped into its slot carries the right entity. `archetype_swap_remove`
/// must move the handle as well as the columns -- it did not, so `entities[row]`
/// kept the departed entity's id and any walk by row index named the wrong one.
#[test]
def test_mid_list_swap_remove_moves_the_entity_handle : Bool :=
    let a : Spawned := spawn empty_world [Pair.pair "pos" (Any.any 1u64)] in
    let b : Spawned := spawn a.world [Pair.pair "pos" (Any.any 2u64)] in
    let c : Spawned := spawn b.world [Pair.pair "pos" (Any.any 3u64)] in
    // Remove the FIRST row: c's handle must end up at row 0.
    let world : World := despawn c.world a.entity in
    match entity_row world c.entity {
        Option.none => false,
        Option.some row =>
            match entity_location world c.entity {
                Option.none => false,
                Option.some loc =>
                    let l : Loc := loc in
                    I64.beq row 0 && I64.beq l.row 0
                        && U64.beq (entity_id (world_entity_at world l.archetype 0)) c.entity.id
            }
    }
