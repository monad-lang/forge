// Mo Venture: which hero a Mo is, and what it can do.
//
// Xiaozhu (小猪, the piggy) and Xiaomao (小猫, the kitty) are two characters
// that travel together: one is controlled, the other follows, and `C` swaps
// roles. Identity and ability constants live here, with NO imports, so the
// controller (`mo.mo`) can use them without a cycle through `look.mo`.

/// Xiaozhu, the piggy (breaks boxes with a body slam).
pub def hero_xiaozhu : I64 := 0

/// Xiaomao, the kitty (climbs walls, spins).
pub def hero_xiaomao : I64 := 1

pub def hero_count : I64 := 2

/// The other hero.
pub def hero_next (h : I64) : I64 := if h == hero_xiaozhu then hero_xiaomao else hero_xiaozhu

pub def hero_name (h : I64) : String := if h == hero_xiaomao then "Xiaomao Mo" else "Xiaozhu Mo"

// ── Abilities ───────────────────────────────────────────────────────

pub def ability_none : I64 := 0

/// Xiaomao's spin: a short whirl that trips switches.
pub def ability_spin : I64 := 1

/// Xiaozhu's body slam: a fast fall that breaks boxes it lands among.
pub def ability_slam : I64 := 2

/// The ability a hero has (the one ability key `X` uses).
pub def hero_ability (h : I64) : I64 :=
    if h == hero_xiaomao then ability_spin else ability_slam

/// One line for the HUD / controls: what this hero's ability is.
pub def ability_name (a : I64) : String :=
    if a == ability_spin then "spin" else if a == ability_slam then "slam" else "none"
