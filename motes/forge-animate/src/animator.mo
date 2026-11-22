// forge-animate: clips and the `Animator` component.
//
// A `Clip` is a set of channels, each one track driving one property of
// one entity: the animator's own entity (target "") or a descendant found
// by its `Name` (forge-scene). Markers are named times; crossing one emits
// an `AnimEvent` to the `"forge.anim_events"` resource for that frame.
//
// An `Animator` plays a clip: time advances by `delta * speed`, and the
// loop mode maps it into the clip (once: clamp; repeat: wrap; ping-pong:
// there and back). `animator_crossfade` blends to a second clip over some
// seconds: the current clip is applied at full weight, then the next one is
// blended over it with weight `w` rising from 0 to 1, so the two weights
// always sum to 1. At `w = 1` the next clip becomes the clip.
//
// `animate_step` is the pure `World -> World` system body; `app_frame`
// propagates transforms after the systems, so a pose is drawn the frame it
// is computed.

use std::derive {derive_copy, derive_clone, derive_debug}
use init::copy {Copy}
use init::clone {Clone}
use init::id {Id}
use forge_core::ecs {World, Entity, Spawned, spawn, insert_component, get_component_named}
use forge_core::query {query_entities}
use forge_core::world_m {WorldM, WorldM.modify}
use forge_math::{f64_floor, f64_min, f64_max}
use forge_scene::{transform_name, find_named}
use forge_schedule {world_time, time_delta}
use lib::pose {Property, write_prop, blend_prop}
use lib::track {Track, track_sample, track_duration}

// ── Clips ───────────────────────────────────────────────────────────

/// One track bound to a target: "" is the animator's entity, anything else
/// names a descendant. `Copy`.
pub struct Channel {
    target : String,
    track : Track
}

pub instance Copy Channel {
    def copy (c : Channel) : Pair Channel Channel := Pair.pair c c
}

pub def channel (target : String) (tr : Track) : Channel := { target := target, track := tr : Channel }

/// A named time in a clip. `Copy`.
#[derive Copy Clone Debug]
pub struct Marker {
    time : F64,
    name : String
}

pub def marker (time : F64) (name : String) : Marker := { time := time, name := name : Marker }

/// Channels, markers and a length. `Copy` (identity: persistent lists).
pub struct Clip {
    channels : List Channel,
    markers : List Marker,
    duration : F64
}

pub instance Copy Clip {
    def copy (c : Clip) : Pair Clip Clip := Pair.pair c c
}

#[terminating]
def longest (cs : List Channel) (acc : F64) : F64 :=
    match cs {
        List.empty => acc,
        List.cons c rest => longest rest (f64_max acc (track_duration c.track))
    }

/// A clip as long as its longest track.
pub def clip (channels : List Channel) (markers : List Marker) : Clip :=
    let sh : Shared (List Channel) := Shared.of channels in
    { channels := Shared.get sh, markers := markers, duration := longest (Shared.get sh) 0.0 : Clip }

/// A clip of exactly `duration` seconds (a loop may end after its last key).
pub def clip_timed (duration : F64) (channels : List Channel) (markers : List Marker) : Clip :=
    { channels := channels, markers := markers, duration := duration : Clip }

pub def clip_empty : Clip := { channels := [], markers := [], duration := 0.0 : Clip }

pub def clip_duration (c : Clip) : F64 := c.duration

// ── Time ────────────────────────────────────────────────────────────

/// How time maps into a clip. `Copy`.
pub type LoopMode {
    loop_once,
    loop_repeat,
    loop_ping_pong
}

pub instance Copy LoopMode {
    def copy (m : LoopMode) : Pair LoopMode LoopMode := Pair.pair m m
}

/// `t` (>= 0) mapped into `[0, dur]` by `mode`.
pub def loop_time (mode : LoopMode) (t : F64) (dur : F64) : F64 :=
    if dur <= 0.0 then 0.0
    else
        match mode {
            LoopMode.loop_once => f64_min dur (f64_max 0.0 t),
            LoopMode.loop_repeat => t - f64_floor (t / dur) * dur,
            LoopMode.loop_ping_pong =>
                let p : F64 := 2.0 * dur in
                let u : F64 := t - f64_floor (t / p) * p in
                if u > dur then p - u else u
        }

// ── The component ───────────────────────────────────────────────────

/// A playing clip, and maybe one it is fading to. `Copy` (identity).
pub struct Animator {
    clip : Clip,
    time : F64,
    speed : F64,
    mode : LoopMode,
    playing : Bool,
    next : Clip,
    next_time : F64,
    fade : F64,
    fade_for : F64
}

pub instance Copy Animator {
    def copy (a : Animator) : Pair Animator Animator := Pair.pair a a
}

/// Play `c` from the start in `mode`, at normal speed.
pub def animator (c : Clip) (mode : LoopMode) : Animator :=
    { clip := c, time := 0.0, speed := 1.0, mode := mode, playing := true, next := clip_empty,
      next_time := 0.0, fade := 0.0, fade_for := 0.0 : Animator }

pub def animator_with_speed (a : Animator) (s : F64) : Animator := { a with speed := s }

/// Start `a` at clip time `t` (offsets between copies of one loop).
pub def animator_at (a : Animator) (t : F64) : Animator := { a with time := t }

pub def animator_playing (a : Animator) (on : Bool) : Animator := { a with playing := on }

/// Blend to `c` (from its start) over `seconds`.
pub def animator_crossfade (a : Animator) (c : Clip) (seconds : F64) : Animator :=
    { a with next := c, next_time := 0.0, fade := 0.0, fade_for := f64_max seconds 0.0001 }

pub def animator_time (a : Animator) : F64 := a.time

pub def animator_is_fading (a : Animator) : Bool := a.fade_for > 0.0

/// The weights of the current and the next clip (they sum to 1).
pub def animator_weights (a : Animator) : Pair F64 F64 :=
    if a.fade_for > 0.0 then Pair.pair (1.0 - a.fade) a.fade else Pair.pair 1.0 0.0

/// Where in the clip the animator is (after the loop mode).
pub def animator_local_time (a : Animator) : F64 := loop_time a.mode a.time a.clip.duration

/// Advance by `dt` seconds of real time.
pub def animator_advance (a : Animator) (dt : F64) : Animator :=
    if Bool.not a.playing then a
    else
        let step : F64 := dt * a.speed in
        if a.fade_for > 0.0
        then
            let f : F64 := a.fade + dt / a.fade_for in
            if f >= 1.0
            then { a with clip := a.next, time := a.next_time + step, next := clip_empty, next_time := 0.0,
                          fade := 0.0, fade_for := 0.0 }
            else { a with time := a.time + step, next_time := a.next_time + step, fade := f }
        else { a with time := a.time + step }

pub def animator_name : String := "forge.animator"

def as_animator (v : Any) : Animator :=
    match v { Any.any x => let a : Animator := x in a }

pub def set_animator (world : World) (e : Entity) (a : Animator) : World :=
    insert_component world e animator_name (Any.any a)

pub def entity_animator (world : World) (e : Entity) : Option Animator :=
    match get_component_named world e animator_name {
        Option.some v => Option.some (as_animator v),
        Option.none => Option.none
    }

// ── Events ──────────────────────────────────────────────────────────

/// A marker crossed this frame. `Copy`.
#[derive Copy Clone Debug]
pub struct AnimEvent {
    entity : Entity,
    name : String
}

pub def anim_event_entity (e : AnimEvent) : Entity := e.entity

pub def anim_event_name (e : AnimEvent) : String := e.name

/// This frame's marker events. `Copy` (identity).
struct AnimEvents {
    events : List AnimEvent
}

instance Copy AnimEvents {
    def copy (e : AnimEvents) : Pair AnimEvents AnimEvents := Pair.pair e e
}

pub def anim_events_name : String := "forge.anim_events"

def as_events (v : Any) : AnimEvents :=
    match v { Any.any x => let e : AnimEvents := x in e }

/// The marker events `animate_step` emitted this frame.
pub def world_anim_events (world : World) : List AnimEvent :=
    match List.first (query_entities world [anim_events_name] []) {
        Option.some e =>
            match get_component_named world e anim_events_name {
                Option.some v => let ev : AnimEvents := as_events v in ev.events,
                Option.none => []
            },
        Option.none => []
    }

def set_events (world : World) (es : List AnimEvent) : World :=
    match List.first (query_entities world [anim_events_name] []) {
        Option.some e => insert_component world e anim_events_name (Any.any { events := es : AnimEvents }),
        Option.none =>
            let s : Spawned := spawn world [Pair.pair anim_events_name (Any.any { events := es : AnimEvents })] in
            s.world
    }

/// Was marker time `m` crossed going from local time `a` to `b`? Forward
/// crossings count `(a, b]`; a wrap (repeat) counts past `a` or up to `b`;
/// a ping-pong turn going backwards counts `[b, a)`.
pub def crossed (mode : LoopMode) (a : F64) (b : F64) (m : F64) : Bool :=
    if b > a then m > a && m <= b
    else if b < a then
        match mode {
            LoopMode.loop_repeat => m > a || m <= b,
            LoopMode.loop_ping_pong => m >= b && m < a,
            LoopMode.loop_once => false
        }
    else false

#[terminating]
def fire (mode : LoopMode) (a : F64) (b : F64) (e : Entity) (ms : List Marker) (acc : List AnimEvent)
    : List AnimEvent :=
    match ms {
        List.empty => acc,
        List.cons m rest =>
            if crossed mode a b m.time
            then fire mode a b e rest (List.cons { entity := e, name := m.name : AnimEvent } acc)
            else fire mode a b e rest acc
    }

// ── Applying a pose ─────────────────────────────────────────────────

def target_of (world : World) (e : Entity) (name : String) : Option Entity :=
    if name == "" then Option.some e else find_named world e name

def apply_channel (world : World) (e : Entity) (t : F64) (w : F64) (c : Channel) : World :=
    match target_of world e c.target {
        Option.some x =>
            let tr : Track := c.track in
            if w >= 1.0 then write_prop world x tr.prop (track_sample tr t)
            else blend_prop world x tr.prop (track_sample tr t) w,
        Option.none => world
    }

#[terminating]
def apply_all (world : World) (e : Entity) (t : F64) (w : F64) (cs : List Channel) : World :=
    match cs {
        List.empty => world,
        List.cons c rest => apply_all (apply_channel world e t w c) e t w rest
    }

/// Pose `e`'s tree from `a`: the clip at full weight, then (while fading)
/// the next clip blended over it.
pub def apply_animator (world : World) (e : Entity) (a : Animator) : World :=
    let w1 : World := apply_all world e (loop_time a.mode a.time a.clip.duration) 1.0 a.clip.channels in
    if a.fade_for > 0.0
    then apply_all w1 e (loop_time a.mode a.next_time a.next.duration) a.fade a.next.channels
    else w1

// ── The system ──────────────────────────────────────────────────────

/// The world and the events gathered so far. `Copy` (identity).
struct AnimRun {
    world : World,
    events : List AnimEvent
}

instance Copy AnimRun {
    def copy (r : AnimRun) : Pair AnimRun AnimRun := Pair.pair r r
}

def step_one (dt : F64) (r : AnimRun) (e : Entity) : AnimRun :=
    match entity_animator r.world e {
        Option.some a0 =>
            let a : Animator := a0 in
            let before : F64 := animator_local_time a in
            let b : Animator := animator_advance a dt in
            let after : F64 := animator_local_time b in
            let evs : List AnimEvent := fire b.mode before after e b.clip.markers r.events in
            { world := apply_animator (set_animator r.world e b) e b, events := evs : AnimRun },
        Option.none => r
    }

#[terminating]
def step_all (dt : F64) (r : AnimRun) (es : List Entity) : AnimRun :=
    match es {
        List.empty => r,
        List.cons e rest => step_all dt (step_one dt r e) rest
    }

/// One frame of every animator, by `dt` seconds.
pub def animate_by (dt : F64) (world : World) : World :=
    let r : AnimRun := step_all dt { world := world, events := [] : AnimRun }
                            (query_entities world [animator_name, transform_name] []) in
    set_events r.world (List.reverse r.events)

/// One frame of every animator, by the world clock's delta.
pub def animate_step (world : World) : World := animate_by (time_delta (world_time world)) world

pub def animate_system : WorldM Id Unit := WorldM.modify animate_step
