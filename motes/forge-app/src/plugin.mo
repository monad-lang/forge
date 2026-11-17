// forge-app: `Plugin`, the unit of app composition. Phase 7, see
// ../../../PLAN.md.
//
// A plugin carries a NAME and an `IO Unit` setup action -- the "build" half of
// a plugin. The other half (the systems it registers) reaches into the
// `Schedule`, which `app.mo` owns, so a plugin that adds systems is expressed
// as `app_add_setup` (a name + a schedule transformer) instead. Both halves are
// plain values, so the whole app is a pure data structure until `run`.

use std::derive {derive_debug}
use std::list {}
use init::copy {Copy}
use forge_schedule {Schedule}

/// A named setup action, run once before the loop starts.
#[derive Debug]
pub struct Plugin {
    name : String,
    setup : IO Unit
}

pub instance Copy Plugin {
    def copy (p : Plugin) : Pair Plugin Plugin := Pair.pair p p
}

pub def plugin_new (name : String) (setup : IO Unit) : Plugin :=
    { name := name, setup := setup : Plugin }

/// A plugin that only has a name (no setup work).
pub def plugin_named (name : String) : Plugin :=
    { name := name, setup := Monad.pure unit : Plugin }

pub def plugin_name (p : Plugin) : String := p.name

pub def plugin_setup (p : Plugin) : IO Unit := p.setup

#[test]
def test_plugin_name : Bool :=
    String.beq (plugin_name (plugin_named "core")) "core"

#[test]
def test_plugin_setup_is_callable : IO Bool := do {
    plugin_setup (plugin_named "core");
    return (true)
}
