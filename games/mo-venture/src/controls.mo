// Mo Venture: the controls. Keys become an `Intent`, relative to the
// camera: W/S (or Up/Down) run along the camera's facing on the ground,
// A/D (or Left/Right) along its right. Space jumps (hold for height).
// Shift held on the ground runs faster; pressed in the air, it dashes.
// P toggles the autopilot.

use forge_app {
    Input, input_axis, input_key_held, input_key_pressed, world_input, Orbit, orbit_forward, orbit_right
}
use forge_math {Vec3, vec3, v3_add, v3_scale}
use lib::mo {Intent, intent}

/// Either key of each pair counts; the sum is clamped to -1..1.
def axis2 (i : Input) (neg : String) (pos : String) (neg2 : String) (pos2 : String) : F64 :=
    let a : F64 := input_axis i neg pos + input_axis i neg2 pos2 in
    if a > 1.0 then 1.0 else if a < 0.0 - 1.0 then 0.0 - 1.0 else a

def shift_held (i : Input) : Bool := input_key_held i "ShiftLeft" || input_key_held i "ShiftRight"

def shift_pressed (i : Input) : Bool := input_key_pressed i "ShiftLeft" || input_key_pressed i "ShiftRight"

/// The player's intent from this frame's keys and the camera.
pub def keys_intent (i : Input) (o : Orbit) : Intent :=
    let m : Vec3 := v3_add (v3_scale (orbit_right o) (axis2 i "KeyA" "KeyD" "ArrowLeft" "ArrowRight"))
                           (v3_scale (orbit_forward o) (axis2 i "KeyS" "KeyW" "ArrowDown" "ArrowUp")) in
    intent m.x m.z (input_key_pressed i "Space") (input_key_held i "Space") (shift_pressed i) (shift_held i)

/// Did the player toggle the autopilot this frame?
pub def autopilot_pressed (i : Input) : Bool := input_key_pressed i "KeyP"
