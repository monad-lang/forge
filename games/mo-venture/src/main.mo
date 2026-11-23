// Mo Venture in the browser: the web bin. Everything here is the three
// exports the web loader calls; the game is `lib::game` and the page (the
// canvas, HUD and touch controls) is an Oak program in `forge_app::web`.
//
//   devenv shell -- scripts/web-serve.sh mo-venture   # http://localhost:8080

use forge_app::web {web_mount, web_dispatch, web_tick}
use lib::level {skyway}
use lib::game {mo_venture, mo_rig}

#[export "c"]
def oak_mount : IO Unit := web_mount mo_venture (mo_rig skyway)

#[export "c"]
def oak_dispatch_event (handler : I64) : IO Unit := web_dispatch handler

#[export "c"]
def oak_tick : IO Unit := web_tick

def main : IO Unit := IO.pure unit
