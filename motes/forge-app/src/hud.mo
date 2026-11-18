// forge-app: the HUD channel. A game's systems write short strings under
// keys ("sparks" -> "3/20"); the host shows them. On the web, `forge_app::web`
// mirrors each CHANGED entry to the canvas as `data-hud-<key>`, which a page
// binds to its own markup (a MutationObserver) and a headless test reads
// back. Natively the entries are just world state a test can inspect.
//
// The resource is a singleton entity under `"forge.hud"`, like `Input`.

use std::derive {}
use init::copy {Copy}
use forge_core::ecs {World, Entity, Spawned, spawn, empty_world, insert_component, get_component_named}
use forge_core::query {query_entities}

/// One key and its text. `Copy` (identity: two strings).
pub struct HudEntry {
    key : String,
    value : String
}

pub instance Copy HudEntry {
    def copy (e : HudEntry) : Pair HudEntry HudEntry := Pair.pair e e
}

pub def hud_entry (key : String) (value : String) : HudEntry := { key := key, value := value : HudEntry }

pub def hud_entry_key (e : HudEntry) : String := e.key

pub def hud_entry_value (e : HudEntry) : String := e.value

/// Every entry, in first-set order. `Copy` (identity).
pub struct Hud {
    entries : List HudEntry
}

pub instance Copy Hud {
    def copy (h : Hud) : Pair Hud Hud := Pair.pair h h
}

pub def hud_empty : Hud := { entries := [] : Hud }

pub def hud_list (h : Hud) : List HudEntry := h.entries

#[terminating]
def put_go (es : List HudEntry) (k : String) (v : String) : List HudEntry :=
    match es {
        List.empty => [hud_entry k v],
        List.cons e rest =>
            if e.key == k then List.cons (hud_entry k v) rest else List.cons e (put_go rest k v)
    }

pub def hud_put (h : Hud) (k : String) (v : String) : Hud := { entries := put_go h.entries k v : Hud }

#[terminating]
def lookup_go (es : List HudEntry) (k : String) : Option String :=
    match es {
        List.empty => Option.none,
        List.cons e rest => if e.key == k then Option.some e.value else lookup_go rest k
    }

pub def hud_lookup (h : Hud) (k : String) : Option String := lookup_go h.entries k

/// The entries of `now` that are new or changed since `prev`: what a host
/// must redraw.
#[terminating]
def changes_go (prev : Hud) (es : List HudEntry) : List HudEntry :=
    match es {
        List.empty => [],
        List.cons e rest =>
            let same : Bool := match hud_lookup prev e.key {
                Option.some v => v == e.value,
                Option.none => false
            } in
            if same then changes_go prev rest else List.cons e (changes_go prev rest)
    }

pub def hud_changes (prev : Hud) (now : Hud) : List HudEntry := changes_go prev now.entries

// ── Resource ────────────────────────────────────────────────────────

pub def hud_name : String := "forge.hud"

def as_hud (v : Any) : Hud :=
    match v { Any.any x => let h : Hud := x in h }

/// The world's HUD (empty until a system writes one).
pub def world_hud (world : World) : Hud :=
    match List.first (query_entities world [hud_name] []) {
        Option.some e =>
            match get_component_named world e hud_name {
                Option.some v => as_hud v,
                Option.none => hud_empty
            },
        Option.none => hud_empty
    }

def spawn_hud (world : World) (h : Hud) : World :=
    let s : Spawned := spawn world [Pair.pair hud_name (Any.any h)] in
    s.world

pub def world_set_hud (world : World) (h : Hud) : World :=
    match List.first (query_entities world [hud_name] []) {
        Option.some e => insert_component world e hud_name (Any.any h),
        Option.none => spawn_hud world h
    }

/// Set one HUD entry.
pub def hud_set (world : World) (k : String) (v : String) : World :=
    world_set_hud world (hud_put (world_hud world) k v)

/// One HUD entry's text.
pub def hud_get (world : World) (k : String) : Option String := hud_lookup (world_hud world) k

// ── Tests ───────────────────────────────────────────────────────────

def is_text (o : Option String) (want : String) : Bool :=
    match o {
        Option.some v => v == want,
        Option.none => false
    }

#[test]
def test_put_replaces_in_place : Bool :=
    let h : Hud := hud_put (hud_put (hud_put hud_empty "a" "1") "b" "2") "a" "3" in
    List.length (hud_list h) == 2 && is_text (hud_lookup h "a") "3"

#[test]
def test_changes_are_new_or_different : Bool :=
    let prev : Hud := hud_put (hud_put hud_empty "a" "1") "b" "2" in
    let now : Hud := hud_put (hud_put prev "b" "5") "c" "7" in
    List.length (hud_changes prev now) == 2

#[test]
def test_world_hud_round_trips : Bool :=
    let w : World := hud_set (hud_set empty_world "sparks" "0/20") "sparks" "1/20" in
    is_text (hud_get w "sparks") "1/20"
