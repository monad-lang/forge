// forge-scene: `Name`, a string label on an entity, so data (an animation
// clip's channels) can address a child by name instead of by an entity id
// that only exists at run time.

use std::derive {derive_copy, derive_clone, derive_debug}
use std::list {List.filter}
use init::copy {Copy}
use init::clone {Clone}
use forge_core::ecs {Entity, World, Spawned, insert_component, get_component_named, empty_world}
use lib::scene {children_of, spawn_transform, spawn_transform_child, transform_identity}

/// An entity's label. `Copy`.
#[derive Copy Clone Debug]
pub struct Name {
    name : String
}

pub def name_name : String := "forge.name"

def as_name (v : Any) : Name :=
    match v { Any.any x => let n : Name := x in n }

/// Label `e` as `n`.
pub def set_name (world : World) (e : Entity) (n : String) : World :=
    insert_component world e name_name (Any.any { name := n : Name })

/// `e`'s label, if it has one.
pub def entity_name (world : World) (e : Entity) : Option String :=
    match get_component_named world e name_name {
        Option.some v => let n : Name := as_name v in Option.some n.name,
        Option.none => Option.none
    }

def named (world : World) (e : Entity) (n : String) : Bool :=
    match entity_name world e {
        Option.some s => s == n,
        Option.none => false
    }

/// The first descendant of `root` (depth first, children before their
/// children) labelled `n`.
#[terminating]
pub def find_named (world : World) (root : Entity) (n : String) : Option Entity :=
    find_in world (children_of world root) n

#[terminating]
def find_in (world : World) (es : List Entity) (n : String) : Option Entity :=
    match es {
        List.empty => Option.none,
        List.cons e rest =>
            if named world e n then Option.some e
            else
                match find_named world e n {
                    Option.some d => Option.some d,
                    Option.none => find_in world rest n
                }
    }

#[test]
def test_find_named_reaches_a_grandchild : Bool :=
    let r : Spawned := spawn_transform empty_world transform_identity in
    let c : Spawned := spawn_transform_child r.world transform_identity r.entity in
    let g : Spawned := spawn_transform_child (set_name c.world c.entity "arm") transform_identity c.entity in
    let w : World := set_name g.world g.entity "hand" in
    match find_named w r.entity "hand" {
        Option.some e => U64.beq e.id g.entity.id && Bool.not (named w r.entity "hand"),
        Option.none => false
    }
