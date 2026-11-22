#!/usr/bin/env bash
# Read a mote's pinned commit out of `mote.lock`.
#
# The lock now contains entries from more than one repository (monad and
# atproto-monad), so "the first git_commit line" is no longer the monad rev.
# Match the entry by mote name instead.
#
#   source scripts/lock-rev.sh
#   rev="$(lock_monad_rev "$root/mote.lock")"
#   rev="$(lock_atproto_rev "$root/mote.lock")"

# lock_rev_for MOTE LOCK
lock_rev_for() {
    awk -v want="$1" '
        /^\[\[mote\]\]/ { name = "" }
        /^name = "/ {
            name = $0
            sub(/^name = "/, "", name)
            sub(/"$/, "", name)
        }
        name == want && /^git_commit = / {
            line = $0
            sub(/^git_commit = "/, "", line)
            sub(/"$/, "", line)
            print line
            exit
        }
    ' "$2"
}

# The monad revision that web_wasm (and the web host JS) is pinned to.
lock_monad_rev() {
    lock_rev_for web_wasm "$1"
}

# The atproto-monad revision (for builds that need its web driver).
lock_atproto_rev() {
    lock_rev_for atproto_web "$1"
}
