// forge-animate: animation. Phase 11, see ../../../PLAN.md.
//
// `ease` (easing curves), `track` (keyframes), `pose` (the transform
// properties animated, as `Vec4`s), `animator` (clips, loop modes,
// crossfade, markers; `animate_system`) and `tween` (one-shot property
// tweens; `tween_system`). All native and pure: a system body is a
// `World -> World` function.

pub use lib::ease {Easing, ease}

pub use lib::pose {
    Property, prop_translation, prop_rotation, prop_scale, v4_of_v3, v4_of_quat, v3_of_v4, quat_of_v4,
    v4_lerp, v4_nlerp_short, prop_blend, prop_is_rotation, prop_get, prop_set, read_prop, write_prop,
    blend_prop
}

pub use lib::track {
    Key, key, key_f64, key_vec3, key_quat, key_time, Track, track, track_prop, track_duration,
    track_sample, track_f64_at, track_vec3_at, track_quat_at
}

pub use lib::animator {
    Channel, channel, Marker, marker, Clip, clip, clip_timed, clip_empty, clip_duration,
    LoopMode, loop_once, loop_repeat, loop_ping_pong, loop_time,
    Animator, animator, animator_with_speed, animator_at, animator_playing, animator_crossfade,
    animator_time, animator_is_fading, animator_weights, animator_local_time, animator_advance,
    animator_name, set_animator, entity_animator,
    AnimEvent, anim_event_entity, anim_event_name, anim_events_name, world_anim_events, crossed,
    apply_animator, animate_by, animate_step, animate_system
}

pub use lib::tween {
    TweenEnd, end_hold, end_remove, end_despawn, Tween, tween, tween_translation, tween_scale,
    tween_rotation, tween_then, tween_value, tween_done, tween_name, set_tween, entity_tween,
    tween_by, tween_step, tween_system
}
