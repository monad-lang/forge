// The co-op wire's tests: quantization, room codes, and every message kind
// surviving an encode/decode round trip. If these drift, two clients stop
// agreeing about the same room.

use lib::{
    NetMsg, coop_protocol, coop_version, code_len, code_alphabet, code_of, code_valid,
    normalize_code, alphabet_has,
    milli_max, to_milli, of_milli, axis_to_wire, axis_of_wire, millis_max, to_millis, of_millis,
    f64_round_i64, net_max_chars, net_encode, net_decode, msg_type,
    WireHero, wire_hero, hero_x, hero_y, hero_z, hero_yaw, hero_grounded,
    WireState, wire_state, state_level, state_sparks, state_total, state_falls, state_seconds,
    state_player, state_companion, state_won,
    WireIntent, wire_intent, wire_neutral, intent_mx, intent_mz, intent_jump_pressed,
    intent_jump_held, intent_dash_pressed, intent_sprint, intent_ability_pressed,
    intent_swap_pressed, intent_is_neutral,
    role_host, role_guest
}

/// `|v|` (the mote has no forge-math dependency: this is the one F64
/// helper these tests need).
def abs_f64 (v : F64) : F64 := if v < 0.0 then 0.0 - v else v

/// Within half a milli-unit, plus room for the binary representation of the
/// two values (0.0005000000000016 is a legal drift at the boundary).
def quantized (a : F64) (b : F64) : Bool := abs_f64 (a - b) <= 0.00051

def near (a : F64) (b : F64) : Bool := quantized a b

def hero_near (h : WireHero) (x : F64) (y : F64) (z : F64) (yaw : F64) : Bool :=
    near (hero_x h) x && near (hero_y h) y && near (hero_z h) z && near (hero_yaw h) yaw

// ── Rounding and quantization ───────────────────────────────────────

#[test]
def test_round_is_half_away_from_zero : Bool :=
    f64_round_i64 2.5 == 3 && f64_round_i64 (0.0 - 2.5) == 0 - 3
        && f64_round_i64 2.4 == 2 && f64_round_i64 (0.0 - 0.4) == 0

/// The property is a BOUND, not a particular rounded digit: quantizing to
/// milli-units moves a value by at most half a milli-unit, whatever the
/// binary representation does on the way.
#[test]
def test_positions_round_trip_within_half_a_millimetre : Bool :=
    quantized (of_milli (to_milli 1.2345)) 1.2345
        && quantized (of_milli (to_milli (0.0 - 62.75))) (0.0 - 62.75)
        && quantized (of_milli (to_milli 0.1234)) 0.1234
        && near (of_milli (to_milli 0.0)) 0.0


/// A value far outside the level is clamped, not wrapped: a hostile peer
/// cannot make a coordinate huge or negative-huge.
#[test]
def test_positions_are_clamped : Bool :=
    to_milli 5000.0 == milli_max
        && to_milli (0.0 - 5000.0) == 0 - milli_max
        && near (of_milli (milli_max * 2)) (I64.to_f64 milli_max / 1000.0)

#[test]
def test_axes_quantize_and_clamp : Bool :=
    axis_to_wire 1.0 == 1000 && axis_to_wire (0.0 - 1.0) == 0 - 1000
        && axis_to_wire 7.0 == 1000 && axis_to_wire (0.0 - 7.0) == 0 - 1000
        && near (axis_of_wire (axis_to_wire 0.5)) 0.5
        && near (axis_of_wire (axis_to_wire (0.0 - 0.25))) (0.0 - 0.25)

#[test]
def test_an_out_of_range_axis_read_is_clamped : Bool :=
    near (axis_of_wire 9000) 1.0 && near (axis_of_wire (0 - 9000)) (0.0 - 1.0)

#[test]
def test_times_round_trip_and_clamp : Bool :=
    near (of_millis (to_millis 12.345)) 12.345
        && to_millis (0.0 - 1.0) == 0
        && to_millis 99999.0 == millis_max

// ── Room codes ──────────────────────────────────────────────────────

#[test]
def test_the_alphabet_excludes_lookalikes : Bool :=
    Bool.not (alphabet_has 48u8) && Bool.not (alphabet_has 49u8)
        && alphabet_has 97u8 && alphabet_has 50u8

#[test]
def test_a_code_is_the_right_length_and_spelling : Bool :=
    let c : String := code_of [0, 1, 2, 3] in
    String.length c == code_len && code_valid c && String.length code_alphabet > 0

#[test]
def test_codes_are_normalized_before_matching : Bool :=
    let c : String := code_of [5, 6, 7, 8] in
    normalize_code (String.concat " " c) == c
        && code_valid (normalize_code c)
        && Bool.not (code_valid "nope")
        && Bool.not (code_valid "toolong")
        && Bool.not (code_valid "")

/// Every code the generator can produce is a valid code (the alphabet and
/// the validator cannot drift apart).
#[test]
def test_generated_codes_validate : Bool :=
    code_valid (code_of [0, 0, 0, 0])
        && code_valid (code_of [31, 31, 31, 31])
        && code_valid (code_of [0 - 1, 0 - 2, 0 - 3, 0 - 4])
        && code_valid (code_of [123456, 98765, 42, 7])

// ── Payloads ────────────────────────────────────────────────────────

#[test]
def test_a_wire_hero_keeps_its_pose : Bool :=
    let h : WireHero := wire_hero 1.5 2.25 (0.0 - 30.125) 0.5 true in
    hero_near h 1.5 2.25 (0.0 - 30.125) 0.5 && hero_grounded h

#[test]
def test_a_wire_intent_keeps_its_buttons : Bool :=
    let i : WireIntent := wire_intent (0.0 - 0.5) 1.0 true false true true true false in
    near (intent_mx i) (0.0 - 0.5) && near (intent_mz i) 1.0
        && intent_jump_pressed i && Bool.not (intent_jump_held i)
        && intent_dash_pressed i && intent_sprint i && intent_ability_pressed i
        && Bool.not (intent_swap_pressed i) && Bool.not (intent_is_neutral i)

#[test]
def test_a_neutral_intent_is_recognizable : Bool :=
    intent_is_neutral wire_neutral
        && Bool.not (intent_is_neutral (wire_intent 0.0 0.0 false true false false false false))

// ── Round trips ─────────────────────────────────────────────────────

def round_trip (m : NetMsg) : Option NetMsg :=
    match net_decode (net_encode m) {
        Result.ok back => Option.some back,
        Result.err _ => Option.none
    }

def typed_as (m : NetMsg) (want : String) : Bool := msg_type m == want

#[test]
def test_hello_round_trips : Bool :=
    match round_trip (NetMsg.hello coop_version "Anders") {
        Option.none => false,
        Option.some m =>
            match m {
                NetMsg.hello v name => v == coop_version && name == "Anders",
                _ => false
            }
    }

#[test]
def test_create_round_trips : Bool :=
    match round_trip NetMsg.create {
        Option.none => false,
        Option.some m => typed_as m "create"
    }

#[test]
def test_join_round_trips_and_normalizes : Bool :=
    let c : String := code_of [1, 2, 3, 4] in
    match net_decode (net_encode (NetMsg.join c)) {
        Result.err _ => false,
        Result.ok m =>
            match m {
                NetMsg.join back => back == c,
                _ => false
            }
    }

#[test]
def test_welcome_round_trips : Bool :=
    match net_decode (net_encode (NetMsg.welcome "ab3d" role_guest "Kim")) {
        Result.err _ => false,
        Result.ok m =>
            match m {
                NetMsg.welcome code role peer =>
                    code == "ab3d" && role == role_guest && peer == "Kim",
                _ => false
            }
    }

#[test]
def test_intent_round_trips : Bool :=
    let sent : WireIntent := wire_intent 0.25 (0.0 - 0.75) true true false true false false in
    match round_trip (NetMsg.intent sent) {
        Option.none => false,
        Option.some m =>
            match m {
                NetMsg.intent got =>
                    near (intent_mx got) 0.25 && near (intent_mz got) (0.0 - 0.75)
                        && intent_jump_pressed got && intent_jump_held got
                        && Bool.not (intent_dash_pressed got) && intent_sprint got,
                _ => false
            }
    }

#[test]
def test_state_round_trips_whole : Bool :=
    let p : WireHero := wire_hero 1.0 0.71 (0.0 - 3.0) 0.0 true in
    let c : WireHero := wire_hero 1.0 0.71 (0.0 - 1.8) 3.14 false in
    let sent : WireState := wire_state 2 7 20 1 41.5 p c false in
    match round_trip (NetMsg.state sent) {
        Option.none => false,
        Option.some m =>
            match m {
                NetMsg.state got =>
                    state_level got == 2 && state_sparks got == 7 && state_total got == 20
                        && state_falls got == 1 && near (state_seconds got) 41.5
                        && Bool.not (state_won got)
                        && hero_near (state_player got) 1.0 0.71 (0.0 - 3.0) 0.0
                        && hero_near (state_companion got) 1.0 0.71 (0.0 - 1.8) 3.14
                        && Bool.not (hero_grounded (state_companion got)),
                _ => false
            }
    }

#[test]
def test_left_and_error_round_trip : Bool :=
    match round_trip (NetMsg.left "the host left") {
        Option.none => false,
        Option.some m =>
            match m {
                NetMsg.left r => r == "the host left",
                _ => false
            }
    } && (match round_trip (NetMsg.error "room_full" "one guest per room") {
        Option.none => false,
        Option.some m =>
            match m {
                NetMsg.error c t => c == "room_full" && t == "one guest per room",
                _ => false
            }
    })

// ── Hostile input ───────────────────────────────────────────────────

def rejected (text : String) : Bool :=
    match net_decode text {
        Result.err _ => true,
        Result.ok _ => false
    }

#[test]
def test_a_non_json_frame_is_rejected : Bool :=
    rejected "not json at all" && rejected "" && rejected "[1,2,3]"

#[test]
def test_an_unknown_kind_is_rejected : Bool :=
    rejected "{\"t\":\"teleport\"}"

#[test]
def test_a_missing_tag_is_rejected : Bool :=
    rejected "{\"level\":1}"

#[test]
def test_a_missing_field_is_rejected : Bool :=
    rejected "{\"t\":\"state\",\"level\":1}"
        && rejected "{\"t\":\"intent\",\"mx\":0}"
        && rejected "{\"t\":\"hello\",\"v\":1}"

/// This wire has no floats, but the `json` mote does not reject one: it
/// collapses `1.5` to `Json.Number.int 1` (truncating toward zero), so
/// `Json.get_num_i64` accepts it. The contract therefore relies on the
/// READERS clamping (`of_milli`/`axis_of_wire`), not on the parser refusing.
/// Pinned here so a change to either side is noticed. (Recording this as a
/// `json` behaviour, not a net.mo bug: see PLAN.md's gap table.)
#[test]
def test_a_float_field_is_truncated_not_rejected : Bool :=
    match net_decode "{\"t\":\"state\",\"level\":1.5,\"sparks\":0,\"total\":0,\"falls\":0,\"time\":0,\"won\":false,\"px\":0,\"py\":0,\"pz\":0,\"pyaw\":0,\"pgrounded\":true,\"cx\":0,\"cy\":0,\"cz\":0,\"cyaw\":0,\"cgrounded\":true}" {
        Result.err _ => false,
        Result.ok m =>
            match m {
                // 1.5 truncates to 1: accepted, and bounded.
                NetMsg.state s => state_level s == 1,
                _ => false
            }
    }

/// Whatever a hostile peer sends for a coordinate, the read is clamped to
/// the wire's bound -- that is the real defence, since the parser lets a
/// float through as a truncated integer.
#[test]
def test_a_huge_coordinate_is_clamped_on_read : Bool :=
    match net_decode "{\"t\":\"state\",\"level\":0,\"sparks\":0,\"total\":0,\"falls\":0,\"time\":0,\"won\":false,\"px\":9223372036854775807,\"py\":-9223372036854775807,\"pz\":0,\"pyaw\":0,\"pgrounded\":true,\"cx\":0,\"cy\":0,\"cz\":0,\"cyaw\":0,\"cgrounded\":true}" {
        Result.err _ => false,
        Result.ok m =>
            match m {
                NetMsg.state s =>
                    hero_x (state_player s) == 1000.0
                        && hero_y (state_player s) == (0.0 - 1000.0),
                _ => false
            }
    }

#[test]
def test_an_oversize_frame_is_rejected : Bool :=
    let padding : String := String.repeat "x" (I64.add net_max_chars 10) in
    rejected (String.concat "{\"t\":\"left\",\"reason\":\"" (String.concat padding "\"}"))

#[test]
def test_a_bad_role_is_rejected : Bool :=
    rejected "{\"t\":\"welcome\",\"code\":\"ab3d\",\"role\":\"admin\",\"peer\":\"x\"}"

#[test]
def test_a_malformed_join_code_is_rejected : Bool :=
    rejected "{\"t\":\"join\",\"code\":\"!!!!\"}" && rejected "{\"t\":\"join\",\"code\":\"toolong\"}"
