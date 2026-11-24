// forge-online: the co-op wire, the contract between two game clients and
// the relay that sits between them.
//
// One room is one host and at most one guest. The host steps the game; the
// guest sends its hero's intent and draws the host's state. The relay is
// dumb: it forwards `state`/`welcome`/`error` toward the guest and `intent`
// toward the host, and decides nothing about the game.
//
// ## Why every number on this wire is an integer
//
// `init` has no decimal parser for `F64` (only `F64.bits_of_string`, which
// answers a raw bit pattern and is a codegen intrinsic), and `Json`'s number
// reader only converts to `I64` (`Json.get_num_i64` rejects floats). So a
// position travels as **milli-units** -- `round(x * 1000)` as an `I64` -- and
// an intent axis as a quantized `-1000..1000`. That keeps the whole wire
// exactly round-trippable and testable, and it means a hostile peer cannot
// hand the game a NaN or a 1e300 to multiply by.
//
// ## Room codes
//
// `code_alphabet` leaves out `0`/`O` and `1`/`I`/`L`, so a code read aloud or
// off a screen cannot be typed two ways. Codes are matched case-insensitively
// (`normalize_code` lower-cases), because a guest types what they see.
//
// Nothing here touches a socket: this module is pure, builds natively and for
// wasm, and is unit-tested natively (`net_tests.mo`).

use std::derive {derive_copy, derive_clone}
use std::map {BTreeMap, Map}
use json::json {Json, Json.parse, Json.to_string, Json.get_num_i64, Json.get_object, Json.object_get}
use init::copy {Copy}

// `Json` is an immutable tree; sharing it is a true copy (the same reason
// forge's `Level` has an identity instance). It lets a decoder read several
// members of one document without threading clones.
pub instance Copy Json {
    def copy (j : Json) : Pair Json Json := Pair.pair j j
}

// ── Protocol ────────────────────────────────────────────────────────

/// The WebSocket subprotocol. A relay that sees anything else refuses the
/// upgrade, so a stale page cannot half-connect.
pub def coop_protocol : String := "forge-coop-1"

/// The wire version carried in `hello`. A peer that answers a different
/// version is a protocol error rather than a silently wrong field.
pub def coop_version : I64 := 1

/// How many characters a room code has.
pub def code_len : I64 := 4

/// The alphabet a room code is drawn from (lower case; `normalize_code`
/// lower-cases, so this is the canonical spelling on the wire).
pub def code_alphabet : String := "abcdefghjkmnpqrstuvwxyz23456789"

/// A room code made of `code_len` chars drawn from `code_alphabet` by
/// `digits` (each value reduced mod the alphabet's length). Pure, so a broker
/// can derive one from a counter and a test can pin the mapping.
#[terminating]
def code_go (digits : List I64) (n : I64) (acc : String) : String :=
    match digits {
        List.empty => acc,
        List.cons d rest =>
            let i : I64 := I64.rem (I64.add (I64.rem d n) n) n in
            code_go rest n (String.concat acc (String.slice code_alphabet i 1))
    }

pub def code_of (digits : List I64) : String :=
    let n : I64 := String.length code_alphabet in
    if n <= 0 then "" else code_go digits n ""

/// Upper-cased, trimmed, lower-cased again: the one spelling a code is
/// compared and stored in (`ab3d`, ` AB3D ` and `Ab3d` are the same room).
pub def normalize_code (s : String) : String := String.to_lowercase (String.trim s)

/// Is `c` (one character) in the alphabet?
#[terminating]
def alphabet_has_go (want : U8) (bs : List U8) : Bool :=
    match bs {
        List.empty => false,
        List.cons b rest => if U8.beq b want then true else alphabet_has_go want rest
    }

pub def alphabet_has (c : U8) : Bool := alphabet_has_go c (String.to_list code_alphabet)

/// Is every byte of `s` in the alphabet? (Codes are ASCII by construction.)
#[terminating]
def code_bytes_ok (bs : List U8) : Bool :=
    match bs {
        List.empty => true,
        List.cons b rest => alphabet_has b && code_bytes_ok rest
    }

/// Is `s` a well-formed room code: the right length, only alphabet chars?
pub def code_valid (s : String) : Bool :=
    let n : String := normalize_code s in
    String.length n == code_len && code_bytes_ok (String.to_list n)

// ── Quantized numbers ───────────────────────────────────────────────

/// How many milli-units make one unit.
pub def milli : F64 := 1000.0

/// The wire's bound for a position, in milli-units (1000 units: far beyond
/// any level, so a legitimate value never trips it).
pub def milli_max : I64 := 1000000

/// Round half away from zero. (`init` has no `round`: `F64.to_i64`
/// truncates toward zero, so the half is added before the conversion.)
pub def f64_round_i64 (v : F64) : I64 :=
    if v >= 0.0 then F64.to_i64 (v + 0.5) else 0 - F64.to_i64 ((0.0 - v) + 0.5)

/// `x` as an integer count of milli-units, clamped to `+-milli_max`.
pub def to_milli (x : F64) : I64 :=
    let n : I64 := f64_round_i64 (x * milli) in
    if n > milli_max then milli_max
    else if n < 0 - milli_max then 0 - milli_max
    else n

/// `n` milli-units as units.
pub def of_milli (n : I64) : F64 :=
    let c : I64 :=
        if n > milli_max then milli_max
        else if n < 0 - milli_max then 0 - milli_max
        else n in
    (I64.to_f64 c) / milli

/// One intent axis: `-1..1` quantized to `-1000..1000`.
pub def axis_to_wire (x : F64) : I64 :=
    if x > 1.0 then 1000
    else if x < 0.0 - 1.0 then 0 - 1000
    else f64_round_i64 (x * milli)

pub def axis_of_wire (n : I64) : F64 :=
    let c : I64 := if n > 1000 then 1000 else if n < 0 - 1000 then 0 - 1000 else n in
    (I64.to_f64 c) / 1000.0

/// A time on the wire, in milli-seconds (bounded to an hour: a game clock
/// longer than that is already nonsense).
pub def millis_max : I64 := 3600000

pub def to_millis (seconds : F64) : I64 :=
    let n : I64 := f64_round_i64 (seconds * milli) in
    if n > millis_max then millis_max else if n < 0 then 0 else n

pub def of_millis (n : I64) : F64 :=
    let c : I64 := if n > millis_max then millis_max else if n < 0 then 0 else n in
    (I64.to_f64 c) / milli

// ── Payloads ────────────────────────────────────────────────────────

/// Where one hero is, as the guest draws it. `Copy` (four integers and a
/// boolean).
#[derive Copy Clone]
pub struct WireHero {
    x : I64,
    y : I64,
    z : I64,
    yaw : I64,
    grounded : Bool
}

pub def wire_hero (x : F64) (y : F64) (z : F64) (yaw : F64) (grounded : Bool) : WireHero :=
    { x := to_milli x, y := to_milli y, z := to_milli z, yaw := to_milli yaw, grounded := grounded
      : WireHero }

pub def hero_x (h : WireHero) : F64 := of_milli h.x

pub def hero_y (h : WireHero) : F64 := of_milli h.y

pub def hero_z (h : WireHero) : F64 := of_milli h.z

pub def hero_yaw (h : WireHero) : F64 := of_milli h.yaw

pub def hero_grounded (h : WireHero) : Bool := h.grounded

/// The run's visible state, as the host ships it. `Copy`.
#[derive Copy Clone]
pub struct WireState {
    level : I64,
    sparks : I64,
    total : I64,
    falls : I64,
    time_ms : I64,
    player : WireHero,
    companion : WireHero,
    won : Bool
}

pub def wire_state (level : I64) (sparks : I64) (total : I64) (falls : I64) (seconds : F64)
    (player : WireHero) (companion : WireHero) (won : Bool) : WireState :=
    { level := level, sparks := sparks, total := total, falls := falls,
      time_ms := to_millis seconds, player := player, companion := companion, won := won : WireState }

pub def state_level (s : WireState) : I64 := s.level

pub def state_sparks (s : WireState) : I64 := s.sparks

pub def state_total (s : WireState) : I64 := s.total

pub def state_falls (s : WireState) : I64 := s.falls

pub def state_seconds (s : WireState) : F64 := of_millis s.time_ms

pub def state_player (s : WireState) : WireHero := s.player

pub def state_companion (s : WireState) : WireHero := s.companion

pub def state_won (s : WireState) : Bool := s.won

/// One frame of a guest's input, as the host reads it: the game's `Intent`
/// in wire form. `mx`/`mz` are the quantized run direction, the rest are the
/// same button states.
#[derive Copy Clone]
pub struct WireIntent {
    mx : I64,
    mz : I64,
    jump_pressed : Bool,
    jump_held : Bool,
    dash_pressed : Bool,
    sprint : Bool,
    ability_pressed : Bool,
    swap_pressed : Bool
}

pub def wire_intent (mx : F64) (mz : F64) (jump_pressed : Bool) (jump_held : Bool)
    (dash_pressed : Bool) (sprint : Bool) (ability_pressed : Bool) (swap_pressed : Bool) : WireIntent :=
    { mx := axis_to_wire mx, mz := axis_to_wire mz, jump_pressed := jump_pressed,
      jump_held := jump_held, dash_pressed := dash_pressed, sprint := sprint,
      ability_pressed := ability_pressed, swap_pressed := swap_pressed : WireIntent }

pub def wire_neutral : WireIntent :=
    wire_intent 0.0 0.0 false false false false false false

pub def intent_mx (i : WireIntent) : F64 := axis_of_wire i.mx

pub def intent_mz (i : WireIntent) : F64 := axis_of_wire i.mz

pub def intent_jump_pressed (i : WireIntent) : Bool := i.jump_pressed

pub def intent_jump_held (i : WireIntent) : Bool := i.jump_held

pub def intent_dash_pressed (i : WireIntent) : Bool := i.dash_pressed

pub def intent_sprint (i : WireIntent) : Bool := i.sprint

pub def intent_ability_pressed (i : WireIntent) : Bool := i.ability_pressed

pub def intent_swap_pressed (i : WireIntent) : Bool := i.swap_pressed

pub def intent_is_neutral (i : WireIntent) : Bool :=
    i.mx == 0 && i.mz == 0 && Bool.not i.jump_pressed && Bool.not i.jump_held
        && Bool.not i.dash_pressed && Bool.not i.sprint && Bool.not i.ability_pressed
        && Bool.not i.swap_pressed

/// The longest message the relay will forward, in characters. A `state`
/// frame is a few hundred; anything past this is a peer trying to spend the
/// other side's memory.
pub def net_max_chars : I64 := 2048

/// One message on the wire. `Copy` (every payload is `Copy`).
#[derive Copy Clone]
pub type NetMsg {
    /// First frame either way: who is on the other end.
    hello (version : I64) (name : String),
    /// Host: open a room. The relay answers `welcome` with the code.
    create,
    /// Guest: join room `code`.
    join (code : String),
    /// The relay's answer to `create`/`join`.
    welcome (code : String) (role : String) (peer : String),
    /// Guest -> host: this frame's intent for the guest's hero.
    intent (i : WireIntent),
    /// Host -> guest: the run's visible state.
    state (s : WireState),
    /// Either way: a co-op session ended.
    left (reason : String),
    /// The relay refused something.
    error (code : String) (message : String)
}

pub def role_host : String := "host"

pub def role_guest : String := "guest"

/// The message's tag, as it appears in the `t` field.
pub def msg_type (m : NetMsg) : String :=
    match m {
        NetMsg.hello _ _ => "hello",
        NetMsg.create => "create",
        NetMsg.join _ => "join",
        NetMsg.welcome _ _ _ => "welcome",
        NetMsg.intent _ => "intent",
        NetMsg.state _ => "state",
        NetMsg.left _ => "left",
        NetMsg.error _ _ => "error"
    }

// ── Encoding ────────────────────────────────────────────────────────
//
// Flat JSON objects with a `t` tag, so a decoder refuses an unknown kind
// before reading any field. Integers only (see the header).

def int_field (k : String) (v : I64) : Pair String Json := Pair.pair k (Json.make_num_int v)

def bool_field (k : String) (v : Bool) : Pair String Json := Pair.pair k (Json.make_bool v)

def str_field (k : String) (v : String) : Pair String Json := Pair.pair k (Json.make_str v)

def hero_fields (prefix : String) (h : WireHero) : List (Pair String Json) :=
    [ int_field (String.concat prefix "x") h.x,
      int_field (String.concat prefix "y") h.y,
      int_field (String.concat prefix "z") h.z,
      int_field (String.concat prefix "yaw") h.yaw,
      bool_field (String.concat prefix "grounded") h.grounded ]

def intent_fields (i : WireIntent) : List (Pair String Json) :=
    [ int_field "mx" i.mx,
      int_field "mz" i.mz,
      bool_field "jp" i.jump_pressed,
      bool_field "jh" i.jump_held,
      bool_field "dp" i.dash_pressed,
      bool_field "sp" i.sprint,
      bool_field "ab" i.ability_pressed,
      bool_field "sw" i.swap_pressed ]

def with_type (t : String) (fields : List (Pair String Json)) : Json :=
    Json.make_object_pairs (List.cons (str_field "t" t) fields)

pub def msg_to_json (m : NetMsg) : Json :=
    match m {
        NetMsg.hello v name => with_type "hello" [int_field "v" v, str_field "name" name],
        NetMsg.create => with_type "create" List.empty,
        NetMsg.join code => with_type "join" [str_field "code" code],
        NetMsg.welcome code role peer =>
            with_type "welcome" [str_field "code" code, str_field "role" role, str_field "peer" peer],
        NetMsg.intent i => with_type "intent" (intent_fields i),
        NetMsg.state s =>
            with_type "state"
                (List.append [ int_field "level" s.level, int_field "sparks" s.sparks,
                               int_field "total" s.total, int_field "falls" s.falls,
                               int_field "time" s.time_ms, bool_field "won" s.won ]
                    (List.append (hero_fields "p" s.player) (hero_fields "c" s.companion))),
        NetMsg.left reason => with_type "left" [str_field "reason" reason],
        NetMsg.error code message =>
            with_type "error" [str_field "code" code, str_field "message" message]
    }

pub def net_encode (m : NetMsg) : String := Json.to_string (msg_to_json m)

// ── Decoding ────────────────────────────────────────────────────────

/// The object a message must be. A value that is not an object reads as an
/// empty one, so every field then reports its own "missing" error -- a
/// better diagnostic than "not an object" on its own.
def object_of (j : Json) : BTreeMap String Json :=
    match Json.get_object j {
        Result.err _ => Map.empty,
        Result.ok o => o
    }

def as_int (k : String) (j : Json) : Result String I64 :=
    match Json.object_get k (object_of j) {
        Option.none => Result.err (String.concat "missing `" (String.concat k "`")),
        Option.some v => Json.get_num_i64 (Json.get_num v)
    }

def as_bool (k : String) (j : Json) : Result String Bool :=
    match Json.object_get k (object_of j) {
        Option.none => Result.err (String.concat "missing `" (String.concat k "`")),
        Option.some v => Json.get_bool v
    }

def as_str (k : String) (j : Json) : Result String String :=
    match Json.object_get k (object_of j) {
        Option.none => Result.err (String.concat "missing `" (String.concat k "`")),
        Option.some v => Json.get_str v
    }

def decode_hello (j : Json) : Result String NetMsg :=
    match as_int "v" j {
        Result.err e => Result.err e,
        Result.ok v =>
            match as_str "name" j {
                Result.err e => Result.err e,
                Result.ok name => Result.ok (NetMsg.hello v name)
            }
    }

def decode_join (j : Json) : Result String NetMsg :=
    match as_str "code" j {
        Result.err e => Result.err e,
        Result.ok code0 =>
            // A match-bound binder stays affine even when its type is `Copy`,
            // so the two reads go through one typed binding.
            let code : String := code0 in
            if code_valid code then Result.ok (NetMsg.join (normalize_code code))
            else Result.err "join: malformed room code"
    }

def decode_welcome (j : Json) : Result String NetMsg :=
    match as_str "code" j {
        Result.err e => Result.err e,
        Result.ok code =>
            match as_str "role" j {
                Result.err e => Result.err e,
                Result.ok role0 =>
                    let role : String := role0 in
                    if Bool.not (role == role_host || role == role_guest)
                    then Result.err "welcome: unknown role"
                    else
                        match as_str "peer" j {
                            Result.err e => Result.err e,
                            Result.ok peer => Result.ok (NetMsg.welcome code role peer)
                        }
            }
    }

def decode_intent (j : Json) : Result String NetMsg :=
    match as_int "mx" j {
        Result.err e => Result.err e,
        Result.ok mx =>
            match as_int "mz" j {
                Result.err e => Result.err e,
                Result.ok mz =>
                    match as_bool "jp" j {
                        Result.err e => Result.err e,
                        Result.ok jp =>
                            match as_bool "jh" j {
                                Result.err e => Result.err e,
                                Result.ok jh =>
                                    match as_bool "dp" j {
                                        Result.err e => Result.err e,
                                        Result.ok dp =>
                                            match as_bool "sp" j {
                                                Result.err e => Result.err e,
                                                Result.ok sp =>
                                                    match as_bool "ab" j {
                                                        Result.err e => Result.err e,
                                                        Result.ok ab =>
                                                            match as_bool "sw" j {
                                                                Result.err e => Result.err e,
                                                                Result.ok sw =>
                                                                    Result.ok (NetMsg.intent
                                                                        { mx := mx, mz := mz,
                                                                          jump_pressed := jp, jump_held := jh,
                                                                          dash_pressed := dp, sprint := sp,
                                                                          ability_pressed := ab,
                                                                          swap_pressed := sw : WireIntent })
                                                            }
                                                    }
                                            }
                                    }
                            }
                    }
            }
    }

/// A hero's five fields under `prefix`.
def decode_hero (prefix : String) (j : Json) : Result String WireHero :=
    match as_int (String.concat prefix "x") j {
        Result.err e => Result.err e,
        Result.ok x =>
            match as_int (String.concat prefix "y") j {
                Result.err e => Result.err e,
                Result.ok y =>
                    match as_int (String.concat prefix "z") j {
                        Result.err e => Result.err e,
                        Result.ok z =>
                            match as_int (String.concat prefix "yaw") j {
                                Result.err e => Result.err e,
                                Result.ok yaw =>
                                    match as_bool (String.concat prefix "grounded") j {
                                        Result.err e => Result.err e,
                                        Result.ok g => Result.ok
                                            { x := x, y := y, z := z, yaw := yaw, grounded := g : WireHero }
                                    }
                            }
                    }
            }
    }

def decode_state (j : Json) : Result String NetMsg :=
    match as_int "level" j {
        Result.err e => Result.err e,
        Result.ok level =>
            match as_int "sparks" j {
                Result.err e => Result.err e,
                Result.ok sparks =>
                    match as_int "total" j {
                        Result.err e => Result.err e,
                        Result.ok total =>
                            match as_int "falls" j {
                                Result.err e => Result.err e,
                                Result.ok falls =>
                                    match as_int "time" j {
                                        Result.err e => Result.err e,
                                        Result.ok time_ms =>
                                            match as_bool "won" j {
                                                Result.err e => Result.err e,
                                                Result.ok won =>
                                                    match decode_hero "p" j {
                                                        Result.err e => Result.err e,
                                                        Result.ok player =>
                                                            match decode_hero "c" j {
                                                                Result.err e => Result.err e,
                                                                Result.ok companion =>
                                                                    Result.ok (NetMsg.state
                                                                        { level := level, sparks := sparks,
                                                                          total := total, falls := falls,
                                                                          time_ms := time_ms, player := player,
                                                                          companion := companion, won := won
                                                                          : WireState })
                                                            }
                                                    }
                                            }
                                    }
                            }
                    }
            }
    }

def decode_left (j : Json) : Result String NetMsg :=
    match as_str "reason" j {
        Result.err e => Result.err e,
        Result.ok reason => Result.ok (NetMsg.left reason)
    }

def decode_error (j : Json) : Result String NetMsg :=
    match as_str "code" j {
        Result.err e => Result.err e,
        Result.ok code =>
            match as_str "message" j {
                Result.err e => Result.err e,
                Result.ok message => Result.ok (NetMsg.error code message)
            }
    }

def decode_tagged (t : String) (j : Json) : Result String NetMsg :=
    if t == "hello" then decode_hello j
    else if t == "create" then Result.ok NetMsg.create
    else if t == "join" then decode_join j
    else if t == "welcome" then decode_welcome j
    else if t == "intent" then decode_intent j
    else if t == "state" then decode_state j
    else if t == "left" then decode_left j
    else if t == "error" then decode_error j
    else Result.err (String.concat "unknown message kind `" (String.concat t "`"))

/// A whole document: size-capped, parsed, then dispatched on `t`.
pub def net_decode (text : String) : Result String NetMsg :=
    if String.length text > net_max_chars
    then Result.err "message is too large"
    else
        match Json.parse text {
            Result.err e => Result.err (String.concat "not JSON: " (Json.ParseError.to_string e)),
            Result.ok j0 =>
                let j : Json := j0 in
                match as_str "t" j {
                    Result.err e => Result.err (String.concat "tag: " e),
                    Result.ok t => decode_tagged t j
                }
        }
