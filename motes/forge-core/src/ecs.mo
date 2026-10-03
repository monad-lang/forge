// Entity, Archetype, ComponentStorage, World -- the core data model for the
// ECS. Gap 1 workaround: no `Map` class, so component lookups are
// `List (Pair String Any)` assoc lists. Gap 2 workaround: `World` is a plain
// struct threaded by convention (take one, return one), not linearly
// enforced.
//
// Codegen/runtime workarounds confirmed against the installed toolchain:
// - Every closure that dot-accesses its parameter annotates that parameter's
//   type explicitly -- an unannotated `fn p => p.field` leaves the
//   dot-access's subject type unresolved at check time.
// - A field projection (`expr.field`) is always bound to a `let` before
//   being passed as an argument to a function that pattern-matches/recurses
//   on it -- passing `expr.field` inline (e.g. `List.length fresh.items`)
//   compiles to mistyped IR (an `i1` where an `i64` is expected) when `expr`
//   was itself built from a struct literal earlier in the same call chain.
// - Struct-update (`{ x with f := v }`) silently keeps the OLD field value
//   instead of applying the override -- every update below is a full
//   explicit literal instead.
// - A recursive function that rebuilds a `List Archetype` must not call
//   ANOTHER recursive function that rebuilds a `List (Pair Entity (List
//   (Pair String Any)))` from inside its own match arm -- compute the inner
//   result first, as a plain `let`, before the outer recursive walk starts.
//   See `remove_entity_row`/`replace_matching_archetype` and the
//   in-place-update branch of `insert_component`.
//
// KNOWN OPEN COMPILER BUG (see ../../../PLAN.md "What is deferred" and the
// gap report filed to plans-monad): once a `World` has an `Archetype`
// holding `Any`-boxed row data (i.e. any real spawn), *any subsequent*
// function that re-derives a fresh `World`/`ComponentStorage` from it --
// even touching a totally unrelated field such as `free_ids` -- corrupts
// that unrelated field (observed as a silently duplicated list). This hits
// `despawn`, `insert_component`, and `remove_component` whenever called on
// a world that already has spawned (non-empty-component) entities. Verified
// down to a two-function, no-archetype-matching-logic repro; not a bug in
// the logic below.

use std::list {List.filter, List.any, List.all, List.contains_by}

pub struct Entity {
    id : U64,
    generation : U64
}

pub def entity_id (e : Entity) : U64 := e.id

pub def entity_beq (a : Entity) (b : Entity) : Bool :=
    U64.beq a.id b.id && U64.beq a.generation b.generation

pub struct Archetype {
    component_types : List String,
    rows : List (Pair Entity (List (Pair String Any)))
}

pub struct ComponentStorage {
    archetypes : List Archetype,
    free_ids : List (Pair U64 U64),
    next_id : U64,
    clock : U64,
    last_changed : List (Pair U64 (List (Pair String U64)))
}

pub struct World {
    storage : ComponentStorage
}

pub def empty_world : World :=
    { storage := {
        archetypes := [],
        free_ids := [],
        next_id := 0u64,
        clock := 0u64,
        last_changed := []
        : ComponentStorage
    } : World }

def component_keys (components : List (Pair String Any)) : List String :=
    List.map (fn (c : Pair String Any) => c.first) components

def string_list_eq_as_set (a : List String) (b : List String) : Bool :=
    List.all (fn k => List.contains_by String.beq k b) a
    && List.all (fn k => List.contains_by String.beq k a) b

def archetype_matches (keys : List String) (arch : Archetype) : Bool :=
    string_list_eq_as_set keys arch.component_types

def entity_exists (storage : ComponentStorage) (entity : Entity) : Bool :=
    List.any
        (fn (arch : Archetype) =>
            List.any (fn (row : Pair Entity (List (Pair String Any))) => entity_beq row.first entity) arch.rows)
        storage.archetypes

def find_row_components (archetypes : List Archetype) (entity : Entity) : Option (List (Pair String Any)) :=
    match archetypes {
        empty => Option.none,
        cons arch rest =>
            match List.first
                (List.filter (fn (row : Pair Entity (List (Pair String Any))) => entity_beq row.first entity) arch.rows)
            {
                Option.some row => Option.some row.second,
                Option.none => find_row_components rest entity
            },
        _ => Option.none
    }

def find_entity_archetype (archetypes : List Archetype) (entity : Entity) : Option Archetype :=
    match archetypes {
        empty => Option.none,
        cons arch rest =>
            let rows := arch.rows in
            if List.any (fn (row : Pair Entity (List (Pair String Any))) => entity_beq row.first entity) rows
            then Option.some arch
            else find_entity_archetype rest entity,
        _ => Option.none
    }

def filter_rows_not_entity
    (rows : List (Pair Entity (List (Pair String Any))))
    (entity : Entity)
    : List (Pair Entity (List (Pair String Any))) :=
    match rows {
        empty => [],
        cons row rest =>
            if entity_beq row.first entity
            then filter_rows_not_entity rest entity
            else List.cons row (filter_rows_not_entity rest entity),
        _ => []
    }

def replace_row_components
    (rows : List (Pair Entity (List (Pair String Any))))
    (entity : Entity)
    (new_components : List (Pair String Any))
    : List (Pair Entity (List (Pair String Any))) :=
    match rows {
        empty => [],
        cons row rest =>
            if entity_beq row.first entity
            then List.cons (Pair.pair entity new_components) (replace_row_components rest entity new_components)
            else List.cons row (replace_row_components rest entity new_components),
        _ => []
    }

def replace_matching_archetype
    (archetypes : List Archetype)
    (keys : List String)
    (new_rows : List (Pair Entity (List (Pair String Any))))
    : List Archetype :=
    match archetypes {
        empty => [],
        cons a rest =>
            if archetype_matches keys a
            then List.cons
                { component_types := a.component_types, rows := new_rows : Archetype }
                (replace_matching_archetype rest keys new_rows)
            else List.cons a (replace_matching_archetype rest keys new_rows),
        _ => []
    }

// Precomputes the filtered row list before the outer archetype recursion
// starts -- see the file-header note on why the two can't nest.
def remove_entity_row (archetypes : List Archetype) (entity : Entity) : List Archetype :=
    match find_entity_archetype archetypes entity {
        Option.none => archetypes,
        Option.some arch =>
            let old_rows := arch.rows in
            let filtered_rows := filter_rows_not_entity old_rows entity in
            let target_keys := arch.component_types in
            replace_matching_archetype archetypes target_keys filtered_rows
    }

def add_row_to_archetypes
    (archetypes : List Archetype)
    (keys : List String)
    (entity : Entity)
    (components : List (Pair String Any))
    : List Archetype :=
    let row := Pair.pair entity components in
    if List.any (archetype_matches keys) archetypes
    then List.map
        (fn (arch : Archetype) => if archetype_matches keys arch
                                   then { component_types := arch.component_types, rows := arch.rows ++ [row] : Archetype }
                                   else arch)
        archetypes
    else archetypes ++ [{ component_types := keys, rows := [row] : Archetype }]

struct Alloc {
    entity : Entity,
    remaining_next_id : U64,
    remaining_free_ids : List (Pair U64 U64)
}

def alloc_id (storage : ComponentStorage) : Alloc :=
    match storage.free_ids {
        cons slot rest =>
            { entity := { id := slot.first, generation := slot.second : Entity },
              remaining_next_id := storage.next_id,
              remaining_free_ids := rest
              : Alloc },
        _ =>
            { entity := { id := storage.next_id, generation := 0u64 : Entity },
              remaining_next_id := U64.add storage.next_id 1u64,
              remaining_free_ids := storage.free_ids
              : Alloc }
    }

def set_key_tick (entries : List (Pair String U64)) (key : String) (tick : U64) : List (Pair String U64) :=
    if List.any (fn (p : Pair String U64) => String.beq p.first key) entries
    then List.map
        (fn (p : Pair String U64) => if String.beq p.first key then Pair.pair key tick else p)
        entries
    else entries ++ [Pair.pair key tick]

def set_entity_changed
    (log : List (Pair U64 (List (Pair String U64))))
    (eid : U64)
    (key : String)
    (tick : U64)
    : List (Pair U64 (List (Pair String U64))) :=
    if List.any (fn (p : Pair U64 (List (Pair String U64))) => U64.beq p.first eid) log
    then List.map
        (fn (p : Pair U64 (List (Pair String U64))) =>
            if U64.beq p.first eid
            then Pair.pair eid (set_key_tick p.second key tick)
            else p)
        log
    else log ++ [Pair.pair eid (set_key_tick [] key tick)]

def touch_all
    (log : List (Pair U64 (List (Pair String U64))))
    (eid : U64)
    (keys : List String)
    (tick : U64)
    : List (Pair U64 (List (Pair String U64))) :=
    match keys {
        empty => log,
        cons k rest => touch_all (set_entity_changed log eid k tick) eid rest tick,
        _ => log
    }

pub def spawn (world : World) (components : List (Pair String Any)) : Pair World Entity :=
    let storage := world.storage in
    let alloc := alloc_id storage in
    let keys := component_keys components in
    let new_clock := U64.add storage.clock 1u64 in
    let new_archetypes := add_row_to_archetypes storage.archetypes keys alloc.entity components in
    let new_log := touch_all storage.last_changed alloc.entity.id keys new_clock in
    let new_storage := {
        archetypes := new_archetypes,
        free_ids := alloc.remaining_free_ids,
        next_id := alloc.remaining_next_id,
        clock := new_clock,
        last_changed := new_log
        : ComponentStorage
    } in
    Pair.pair { storage := new_storage : World } alloc.entity

pub def despawn (world : World) (entity : Entity) : World :=
    let storage := world.storage in
    if Bool.not (entity_exists storage entity)
    then world
    else
        let updated_archetypes := remove_entity_row storage.archetypes entity in
        let freed_slot := Pair.pair entity.id (U64.add entity.generation 1u64) in
        { storage := {
            archetypes := updated_archetypes,
            free_ids := storage.free_ids ++ [freed_slot],
            next_id := storage.next_id,
            clock := storage.clock,
            last_changed := storage.last_changed
            : ComponentStorage
        } : World }

pub def insert_component (world : World) (entity : Entity) (key : String) (value : Any) : World :=
    let storage := world.storage in
    match find_row_components storage.archetypes entity {
        Option.none => world,
        Option.some existing =>
            let has_key := List.any (fn (kv : Pair String Any) => String.beq kv.first key) existing in
            let new_clock := U64.add storage.clock 1u64 in
            let new_log := set_entity_changed storage.last_changed entity.id key new_clock in
            if has_key
            then
                let updated_components :=
                    List.map
                        (fn (kv : Pair String Any) => if String.beq kv.first key then Pair.pair key value else kv)
                        existing in
                match find_entity_archetype storage.archetypes entity {
                    Option.none => world,
                    Option.some arch =>
                        let old_rows := arch.rows in
                        let new_rows := replace_row_components old_rows entity updated_components in
                        let target_keys := arch.component_types in
                        let updated_archetypes := replace_matching_archetype storage.archetypes target_keys new_rows in
                        { storage := {
                            archetypes := updated_archetypes,
                            free_ids := storage.free_ids,
                            next_id := storage.next_id,
                            clock := new_clock,
                            last_changed := new_log
                            : ComponentStorage
                        } : World }
                }
            else
                let updated_components := existing ++ [Pair.pair key value] in
                let removed := remove_entity_row storage.archetypes entity in
                let new_keys := component_keys updated_components in
                let added := add_row_to_archetypes removed new_keys entity updated_components in
                { storage := {
                    archetypes := added,
                    free_ids := storage.free_ids,
                    next_id := storage.next_id,
                    clock := new_clock,
                    last_changed := new_log
                    : ComponentStorage
                } : World }
    }

pub def remove_component (world : World) (entity : Entity) (key : String) : World :=
    let storage := world.storage in
    match find_row_components storage.archetypes entity {
        Option.none => world,
        Option.some existing =>
            if Bool.not (List.any (fn (kv : Pair String Any) => String.beq kv.first key) existing)
            then world
            else
                let remaining :=
                    List.filter (fn (kv : Pair String Any) => Bool.not (String.beq kv.first key)) existing in
                let removed := remove_entity_row storage.archetypes entity in
                let new_keys := component_keys remaining in
                let added := add_row_to_archetypes removed new_keys entity remaining in
                { storage := {
                    archetypes := added,
                    free_ids := storage.free_ids,
                    next_id := storage.next_id,
                    clock := storage.clock,
                    last_changed := storage.last_changed
                    : ComponentStorage
                } : World }
    }

pub def changed_since (world : World) (entity : Entity) (key : String) (last_seen : U64) : Bool :=
    let log := world.storage.last_changed in
    match List.first (List.filter (fn (p : Pair U64 (List (Pair String U64))) => U64.beq p.first entity.id) log) {
        Option.some p =>
            let entries := p.second in
            match List.first (List.filter (fn (kv : Pair String U64) => String.beq kv.first key) entries) {
                Option.some kv => U64.gt kv.second last_seen,
                Option.none => false
            },
        Option.none => false
    }

#[test]
def test_entity : Bool := U64.beq (entity_id { id := 1u64, generation := 0u64 : Entity }) 1u64
