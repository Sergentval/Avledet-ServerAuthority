# Phase 2.5 — Avledet ownership-flip patch

**Status:** spec, ready for implementation.
**Predecessor:** [`PHASE-2-SPEC.md`](./PHASE-2-SPEC.md). Phase 2's chase Lua works correctly but is dead code in practice — Avledet flips ZDO ownership to peers via spatial proximity *before* our 12 m aggro radius can fire. This phase fixes that at the source.

## Goal

Make ZDO ownership *sticky* once the server has claimed a ZDO. Spatial-proximity flips should respect server ownership: if the server owns a ZDO, peers don't steal it just by walking nearby. This unlocks Phase 2's chase logic and is the foundational fix for every future server-authoritative-AI phase.

After Phase 2.5 ships:
- Walking near a server-claimed Greydwarf no longer flips it to client. The Greydwarf keeps idle-walking server-side until our Phase 2 chase triggers at 12 m.
- The C# `Sergentval/Valheim-serverside` mod's "mobs don't freeze on disconnect" guarantee extends to "mobs don't even leave server authority just because someone walked past."
- Multi-player coexistence isn't broken: peers can still claim previously-unowned ZDOs, just not those the server has explicitly taken.

## Out of scope for Phase 2.5

- Per-prefab whitelisting (all server-owned ZDOs become sticky uniformly — fine; ServerAuthority decides what to claim, the patch just preserves those decisions).
- Vanilla Valheim client modification (we do not touch the client).
- Performance optimizations to `AssignOrReleaseZDOs` itself.

## Avledet code paths affected

The two flip sites are both in `library/src/ZDOManager.cpp::IZDOManager::AssignOrReleaseZDOs`:

**Site 1 — proximity-grab (line ~488):**

```cpp
} else {
    // If ZDO no longer has owner, or the owner went far away,
    //  Then assign this new peer as owner
    if (!(zdo->has_owner() && ZoneManager()->IsPeerNearby(zdo->get_zone(), zdo->get_owner()))
        && ZoneManager()->ZonesOverlap(zdo->get_zone(), zone)) {

        zdo->set_owner(peer->GetUserID());
    }
}
```

The condition triggers because the *server* doesn't count as a "peer" for `IsPeerNearby` purposes — so any server-owned ZDO is treated as "owner is far away," and any approaching peer claims it.

**Site 2 — smart-reassign (line ~567):**

```cpp
for (auto &&zdo : zdos) {
    if (zdo->is_persistent()
        && zdo->get_position().sq_distance_to(closestPos)
                   > DIST_SMART * DIST_SMART
    ) {
        zdo->set_owner(peer->GetUserID());
    }
}
```

This reassigns ZDOs to whichever peer is geometrically closest. Same problem: server isn't a peer, so its claims don't survive.

## The patch

Single guard in both sites: **if the current owner is the server itself, do not flip.**

The server's UserID is available via `Avledet()->ID()` (we use it from Lua as `Avledet.id`).

```cpp
// SITE 1: in the else branch, before set_owner:
if (zdo->has_owner() && zdo->get_owner() == Avledet()->ID()) {
    continue; // Server-owned ZDOs are sticky — don't flip to peer.
}
if (!(zdo->has_owner() && ZoneManager()->IsPeerNearby(zdo->get_zone(), zdo->get_owner()))
    && ZoneManager()->ZonesOverlap(zdo->get_zone(), zone)) {
    zdo->set_owner(peer->GetUserID());
}

// SITE 2: in the loop body:
if (zdo->is_persistent()
    && zdo->get_owner() != Avledet()->ID()  // <-- new guard
    && zdo->get_position().sq_distance_to(closestPos)
               > DIST_SMART * DIST_SMART
) {
    zdo->set_owner(peer->GetUserID());
}
```

Net change: ~6 lines of C++ across `library/src/ZDOManager.cpp`.

### Why a hard rule rather than a Lua hook

A hook-based design (`ZDOManager:on_should_flip(zdo, peer) -> bool`) would be more flexible but adds:
- A new sol2 binding
- Per-flip Lua callback overhead (this loop runs on every peer move)
- Complexity: callbacks during ownership mutation can race with Lua-driven ownership changes

The hard rule is simpler, faster, and correct for our use case. If a future phase needs per-ZDO opt-out from the sticky behavior, we add a `ZDO::is_unsticky()` method and check that — but Phase 2.5 doesn't need it.

## Side-effects audit

What this patch does NOT break:
- **Server uninstalls ServerAuthority** — server still has its session ID; the patch is a no-op for ZDOs the server never claims (they stay peer-owned).
- **Multi-peer coexistence** — peers still flip ZDOs among themselves. Only ZDOs the *server* owns are sticky.
- **Peer disconnect** — vanilla path: peer's ZDOs become ownerless, server claims them via our ServerAuthority sweep. Now they STAY server-owned across reconnects.
- **Crafting stations / signs / chests** owned by peers — never touched (server doesn't claim them).

What it DOES change observably:
- **Server-claimed mobs stay server-owned** when players approach. Phase 2 chase logic now actually fires.
- **Server-claimed structures, items, terrain mods stay server-owned** — players can still interact with them (structures aren't simulated by owners; they're just data).

## Implementation plan

| ID | Task | Files |
|---|---|---|
| **P2.5-A** | Roll back the dead Phase 2 chase Lua. Keep mob_registry's `hostile`/`aggro_radius` fields (they're correct, just inert). | `lua/scripts/ServerAuthority/stub_ai.lua` |
| **P2.5-B** | Patch `library/src/ZDOManager.cpp` per "The patch" above. | local `Avledet/library/src/ZDOManager.cpp` |
| **P2.5-C** | Rebuild Avledet (`cmake --build build`) and redeploy via systemd restart. | `/home/ubuntu/avledet-spike/...` |
| **P2.5-D** | Re-enable Phase 2 chase Lua (revert P2.5-A) once the patch is verified to not break anything. | `lua/scripts/...` |
| **P2.5-E** | Smoke test: walk into 12 m of a Greydwarf, observe both server log fire and visible chase. | live |
| **P2.5-F** | Open upstream PR #7 to `crazicrafter1/Avledet` with the patch + a clean PR description explaining the use-case. | github |

## Smoke test (P2.5-E) success criteria

1. Boot Avledet built with the patch.
2. Connect from Windows client.
3. Disconnect (server claims everything as usual).
4. Reconnect.
5. Walk toward a Greydwarf in the Black Forest.
6. **Pass:** at ~12 m the server log fires `[StubAI] Greydwarf zdo=X aggro on player at ~12m`.
7. **Pass:** in-game, the Greydwarf turns and walks toward the player using *our* server tick (verifiable from the log line; vanilla AI on client wouldn't write this line).
8. Run away to ~25 m.
9. **Pass:** server log fires `drop aggro (out of range)`.

## Effort estimate

- C++ patch: 5-10 minutes (3 line changes, comment, recompile).
- Rebuild Avledet: 1-3 min incremental (only ZDOManager.cpp changes).
- Smoke test: 10-15 min wall-clock (find Greydwarf, observe behavior).
- Upstream PR: 20 min.

**Total: 30-60 minutes wall-clock.**

## After Phase 2.5

This is the unlock. With the patch in place, every future server-authoritative AI phase (Phase 3 pathfinder, Phase 4 combat, Phase 6 per-mob configs) actually runs server-side when players are near. Without it, those phases are decorative for "no-player-nearby" scenarios only.

Phase 2.5 is also a strong candidate for **upstream contribution** — other Avledet users probably want server-authoritative ZDO ownership for similar reasons (anti-cheat-shaped goals, persistent world events, etc).
