pub type Entity {
  entity (id : U64, generation : U64)
}

pub def entity_id (e : Entity) : U64 :=
  match e {
    Entity.entity id _ => id
  }

#[test]
def test_entity : Bool := U64.beq (entity_id (Entity.entity 1u64 0u64)) 1u64
