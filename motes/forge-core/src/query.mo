// Query iteration and change detection over a World's archetypes.
//
// A query is written with component NAMES (the ergonomic surface); at
// iteration time the names are interned to `ComponentId`s and matched against
// each archetype's sorted id set. Only archetypes that carry EVERY required
// component contribute rows, and each returned row carries everything the
// entity holds (filter with `row_select` for just the requested components).

use lib::ecs {
    Entity, World, Archetype, ComponentId,
    has_id, archetype_rows, archetype_has_all, archetype_row_pairs,
    lookup_component, ids_of_names, changed_since
}
use init::shared {Shared}
use std::derive {}

#[derive Copy Clone Debug]
pub struct Query {
    reads : List String,
    writes : List String
}

pub def query_new (reads : List String) (writes : List String) : Query :=
    { reads := reads, writes := writes : Query }

/// The full component set a query requires, in order.
pub def query_required (q : Query) : List String := List.append q.reads q.writes

// ── Row projection ──────────────────────────────────────────────────

/// Keep only the entries whose `ComponentId` is in `want`.
#[terminating]
def select_go
    (pairs : List (Pair ComponentId Any))
    (want : Shared (List ComponentId))
    : List (Pair ComponentId Any) :=
    match pairs {
        List.empty => [],
        List.cons p rest =>
            match p {
                Pair.pair c _ =>
                    if has_id (Shared.get want) c
                    then List.cons p (select_go rest want)
                    else select_go rest want
            }
    }

/// Project a row down to just the components in `want` (interned ids).
pub def row_select (pairs : List (Pair ComponentId Any)) (want : List ComponentId) : List (Pair ComponentId Any) :=
    select_go pairs (Shared.of want)

// ── Matching ────────────────────────────────────────────────────────

/// Every entity carrying all of `reads ++ writes`.
#[terminating]
def entities_go
    (archs : List Archetype)
    (required : Shared (List ComponentId))
    : List Entity :=
    match archs {
        List.empty => [],
        List.cons a rest =>
            if archetype_has_all a (Shared.get required)
            then List.append a.entities (entities_go rest required)
            else entities_go rest required
    }

pub def query_entities (world : World) (reads : List String) (writes : List String) : List Entity :=
    let required : List ComponentId := ids_of_names world (List.append reads writes) in
    entities_go world.storage.archetypes (Shared.of required)

/// Every row of one archetype, as `(entity, component row)` pairs.
#[terminating]
def rows_of_arch (a : Archetype) (i : I64) : List (Pair Entity (List (Pair ComponentId Any))) :=
    if I64.lt i (archetype_rows a)
    then
        match List.get i a.entities {
            Option.none => rows_of_arch a (I64.add i 1),
            Option.some e =>
                List.cons (Pair.pair e (archetype_row_pairs a i)) (rows_of_arch a (I64.add i 1))
        }
    else []

#[terminating]
def rows_go
    (archs : List Archetype)
    (required : Shared (List ComponentId))
    : List (Pair Entity (List (Pair ComponentId Any))) :=
    match archs {
        List.empty => [],
        List.cons a rest =>
            if archetype_has_all a (Shared.get required)
            then List.append (rows_of_arch a 0) (rows_go rest required)
            else rows_go rest required
    }

/// Every matching `(entity, component row)`.
pub def query_iter
    (world : World)
    (reads : List String)
    (writes : List String)
    : List (Pair Entity (List (Pair ComponentId Any))) :=
    let required : List ComponentId := ids_of_names world (List.append reads writes) in
    rows_go world.storage.archetypes (Shared.of required)

// ── Change detection ────────────────────────────────────────────────

#[derive Copy Clone Debug]
pub struct ChangedFilter {
    key : String,
    last_seen : U64
}

/// Does `entity`'s component `key` pass the `last_seen` cutoff?
pub def passes_changed_filter (world : World) (entity : Entity) (filter : ChangedFilter) : Bool :=
    match lookup_component world.storage.registry filter.key {
        Option.none => false,
        Option.some c => changed_since world entity c filter.last_seen
    }
