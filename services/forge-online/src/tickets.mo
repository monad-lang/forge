// Co-op tickets: mint a single-use, short-lived upgrade credential for a
// signed-in player.
//
// The policy (TTL, single use, the bound, the token shape) lives in
// `forge_online::rooms` and is unit-tested there. This module only supplies
// what the pure contract cannot: the clock, real entropy, and a `Ref` so the
// minting route and the relay's consuming route share one table.

use std::random {Random, RandomError, RandomError.to_string}
use std::ref {Ref, Ref.get, Ref.set}
use crypto::random {CryptoRandom}
use forge_online::{
    TicketTable, tickets_new, ticket_mint, minted_table, minted_token, ticket_sweep, Minted
}

/// The broker's ticket table (shared) and the entropy source.
pub struct TicketSource {
    table : Ref TicketTable,
    entropy : CryptoRandom
}

// A `Ref` handle plus a marker type: sharing it shares the one table, which
// is the point.
pub instance Copy TicketSource {
    def copy (t : TicketSource) : Pair TicketSource TicketSource := Pair.pair t t
}

pub def ticket_source_new : IO TicketSource := do {
    let table <- Ref.new tickets_new;
    IO.pure { table := table, entropy := CryptoRandom.new : TicketSource }
}

/// The shared table (the relay takes this handle to consume from).
pub def ticket_source_table (t : TicketSource) : Ref TicketTable := t.table

/// How many bytes of entropy a token carries (32 bytes -> 43 base64url chars,
/// the same size OAuth's PKCE verifier uses).
pub def ticket_entropy_bytes : I64 := 32

/// Mint a ticket for `subject` at `now`, returning the token.
pub def ticket_issue (t : TicketSource) (subject : String) (now : I64)
    : IO (Result String Minted) := do {
    let r <- Random.token t.entropy ticket_entropy_bytes;
    match r {
        Result.err e => ticket_issue_failed e,
        Result.ok ent => do {
            let table <- Ref.get t.table;
            match ticket_mint table subject ent now {
                Result.err e => IO.pure (Result.err e),
                Result.ok m => ticket_store t m
            }
        }
    }
}

def ticket_issue_failed (e : RandomError) : IO (Result String Minted) :=
    IO.pure (Result.err (RandomError.to_string e))

/// Record the mint, then hand the caller the `Minted` whose token it needs.
/// (`Minted` is `Copy`, so this reads its two fields once each.)
def ticket_store (t : TicketSource) (m : Minted) : IO (Result String Minted) := do {
    let _ <- Ref.set t.table (minted_table m);
    IO.pure (Result.ok m)
}

/// Drop expired tickets (a periodic sweep; the consume path already ignores
/// them, so this is only about keeping the table small).
pub def ticket_swept (t : TicketSource) (now : I64) : IO Unit := do {
    let table <- Ref.get t.table;
    let _ <- Ref.set t.table (ticket_sweep table now);
    IO.pure unit
}
