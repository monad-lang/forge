// forge-collide: contact events.
//
// `collision_system` (update stage) finds this frame's overlapping pairs
// (broad phase, then the narrow phase) and diffs them against last frame's
// to get the pairs that STARTED and ENDED touching. All three lists live in
// the `"forge.contacts"` resource, which systems read like `Input`.
// Triggers are included: a trigger's "started" is its enter, "ended" its
// exit.

use std::derive {}
use init::copy {Copy}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, spawn, insert_component, get_component_named, entity_id}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use lib::narrow {Proximity, proximity}
use lib::world {Scene, Entry, Candidate, collision_scene, broad_phase, same_entity}

/// An unordered pair of entities, stored with the smaller id first. `Copy`.
#[derive Copy Clone]
pub struct PairKey {
    a : Entity,
    b : Entity
}

pub def pair_key (x : Entity) (y : Entity) : PairKey :=
    if entity_id x < entity_id y then { a := x, b := y : PairKey } else { a := y, b := x : PairKey }

pub def pair_a (k : PairKey) : Entity := k.a

pub def pair_b (k : PairKey) : Entity := k.b

pub def key_eq (k : PairKey) (j : PairKey) : Bool := same_entity k.a j.a && same_entity k.b j.b

/// Does the pair involve `e`? Then the other entity.
pub def pair_other (k : PairKey) (e : Entity) : Option Entity :=
    if same_entity k.a e then Option.some k.b
    else if same_entity k.b e then Option.some k.a
    else Option.none

/// This frame's touching pairs and the change since last frame. `Copy`.
pub struct Contacts {
    current : List PairKey,
    started : List PairKey,
    ended : List PairKey
}

pub instance Copy Contacts {
    def copy (c : Contacts) : Pair Contacts Contacts := Pair.pair c c
}

pub def contacts_empty : Contacts := { current := [], started := [], ended := [] : Contacts }

pub def contacts_current (c : Contacts) : List PairKey := c.current

pub def contacts_started (c : Contacts) : List PairKey := c.started

pub def contacts_ended (c : Contacts) : List PairKey := c.ended

#[terminating]
pub def key_in (k : PairKey) (ks : List PairKey) : Bool :=
    match ks {
        List.empty => false,
        List.cons j rest => key_eq k j || key_in k rest
    }

/// The keys of `xs` that are not in `ys`.
#[terminating]
def minus (xs : List PairKey) (ys : Contacts) (acc : List PairKey) : List PairKey :=
    match xs {
        List.empty => acc,
        List.cons x rest => if key_in x ys.current then minus rest ys acc else minus rest ys (List.cons x acc)
    }

#[terminating]
def touching (cs : List Candidate) (acc : List PairKey) : List PairKey :=
    match cs {
        List.empty => acc,
        List.cons c rest =>
            let p : Proximity := proximity c.a.collider.shape c.a.pose c.b.collider.shape c.b.pose in
            if p.distance <= 0.0
            then touching rest (List.cons (pair_key c.a.entity c.b.entity) acc)
            else touching rest acc
    }

/// Every touching pair in a scene.
pub def touching_pairs (s : Scene) : List PairKey := touching (broad_phase s) []

/// The next frame's contacts, given last frame's and this frame's pairs.
pub def contacts_next (prev : Contacts) (now : List PairKey) : Contacts :=
    let cur : Contacts := { current := now, started := [], ended := [] : Contacts } in
    { current := cur.current,
      started := minus cur.current prev [],
      ended := minus prev.current cur []
      : Contacts }

/// The other entities whose contact with `e` is in `ks`.
#[terminating]
pub def partners (e : Entity) (ks : List PairKey) : List Entity :=
    match ks {
        List.empty => [],
        List.cons k rest =>
            match pair_other k e {
                Option.some o => List.cons o (partners e rest),
                Option.none => partners e rest
            }
    }

// ── Resource ────────────────────────────────────────────────────────

pub def contacts_name : String := "forge.contacts"

def as_contacts (v : Any) : Contacts :=
    match v { Any.any x => let c : Contacts := x in c }

/// The world's contacts (`contacts_empty` before the first update).
pub def world_contacts (world : World) : Contacts :=
    match List.first (query_entities world [contacts_name] []) {
        Option.some e =>
            match get_component_named world e contacts_name {
                Option.some v => as_contacts v,
                Option.none => contacts_empty
            },
        Option.none => contacts_empty
    }

def spawn_contacts (world : World) (c : Contacts) : World :=
    let s : Spawned := spawn world [Pair.pair contacts_name (Any.any c)] in
    s.world

pub def world_set_contacts (world : World) (c : Contacts) : World :=
    match List.first (query_entities world [contacts_name] []) {
        Option.some e => insert_component world e contacts_name (Any.any c),
        Option.none => spawn_contacts world c
    }

/// Recompute the contacts resource from the world's colliders.
pub def contacts_update (world : World) : World :=
    let prev : Contacts := world_contacts world in
    let now : List PairKey := touching_pairs (collision_scene world) in
    world_set_contacts world (contacts_next prev now)

/// The system form, for the update stage (after movement).
pub def collision_system : WorldM Id Unit := WorldM.modify contacts_update

/// Entities that started touching `e` this frame.
pub def started_with (world : World) (e : Entity) : List Entity :=
    partners e (contacts_started (world_contacts world))

/// Entities that stopped touching `e` this frame.
pub def ended_with (world : World) (e : Entity) : List Entity :=
    partners e (contacts_ended (world_contacts world))

/// Entities touching `e` this frame.
pub def touching_with (world : World) (e : Entity) : List Entity :=
    partners e (contacts_current (world_contacts world))
