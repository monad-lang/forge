// Query iteration and change detection over a World's archetypes.

use lib::ecs {Entity, World, Archetype, entity_beq, changed_since}
use std::list {List.filter, List.all, List.contains_by}

pub struct Query {
    reads : List String,
    writes : List String
}

def is_subset (needed : List String) (available : List String) : Bool :=
    List.all (fn k => List.contains_by String.beq k available) needed

def select_keys (wanted : List String) (components : List (Pair String Any)) : List (Pair String Any) :=
    List.filter (fn (kv : Pair String Any) => List.contains_by String.beq kv.first wanted) components

def collect_rows
    (archetypes : List Archetype)
    (required : List String)
    : List (Pair Entity (List (Pair String Any))) :=
    match archetypes {
        empty => [],
        cons arch rest =>
            List.map
                (fn (row : Pair Entity (List (Pair String Any))) => Pair.pair row.first (select_keys required row.second))
                arch.rows
            ++ collect_rows rest required,
        _ => []
    }

pub def query_iter
    (world : World)
    (reads : List String)
    (writes : List String)
    : List (Pair Entity (List (Pair String Any))) :=
    let required := reads ++ writes in
    let matching_archetypes :=
        List.filter (fn (arch : Archetype) => is_subset required arch.component_types) world.storage.archetypes in
    collect_rows matching_archetypes required

pub struct ChangedFilter {
    key : String,
    last_seen : U64
}

pub def passes_changed_filter (world : World) (entity : Entity) (filter : ChangedFilter) : Bool :=
    changed_since world entity filter.key filter.last_seen
