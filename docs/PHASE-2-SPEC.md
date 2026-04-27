# Phase 2 — Aggro + chase specification

**Status:** draft, ready for parallel implementation. Builds on the validated Phase 1 stub-AI architecture.
**Predecessor:** [`PHASE-1-SPEC.md`](./PHASE-1-SPEC.md), shipped as `v0.1.0-stub-ai` 2026-04-27.

## Goal

Hostile mobs detect players within an aggro radius and walk toward them. **No damage yet** — that's Phase 4. This phase delivers the felt behaviour: a Greydwarf you walk toward will see you, turn, and pursue. Walk far enough away and it gives up.

After Phase 2 ships:

- A player approaching a server-owned Greydwarf gets visibly chased.
- A player who runs ~18m away (1.5× the default 12m aggro radius) gets dropped from aggro and the mob returns to idle.
- Multiple mobs in range each pick their own target (nearest player wins).
- Passive mobs (Boar/Deer/Greyling/Neck) still do nothing — phase scope keeps it small.

**Phase 2 ships when:** the smoke test (P2-D below) shows a Greydwarf reliably tracking the player from idle, ending in either a "give up" event or a "kept following until inside attack range" state (no combat happens because no Phase 4 yet).

## Out of scope for Phase 2

- Damage / hit detection (Phase 4)
- Pathfinding around obstacles — chase is straight-line, mobs may walk into walls (Phase 3)
- Line-of-sight checks — vegetation/buildings are not yet considered (Phase 3+)
- Per-mob unique combat moves (Phase 6)
- Tameables / passive-aggressive provoke-on-attack — needs damage system first (Phase 4+)
- Group aggro / pack behaviour (later phase)

## Architecture

### State machine extension

Phase 1 had `idle ↔ walking`. Phase 2 adds `chasing` as a third state with explicit transitions:

```
        ┌─────┐                                        ┌────────┐
        │idle │←─────────────────────────────────────→│walking │
        └──┬──┘                                        └───┬────┘
           │                                              │
           │   aggro_target_in_range AND hostile          │
           │   (per tick, when scan fires)                │
           ↓                                              ↓
        ┌─────────────────────────────────────────────────┐
        │              chasing                             │
        │  per tick: step toward target.pos               │
        │  exit: target out of range × 1.5 OR target nil  │
        └─────────────────────────────────────────────────┘
              ↓ (drop)
            idle
```

Aggro-scan throttle: once per `aggro_scan_interval_seconds` (default 1.0s, same as the existing tick rate). Don't scan players from the chase state — once locked, we just track that one target until drop conditions trigger.

### Target tracking

`state.target_player_zdo` (ZDO reference) holds the locked player. Per chase tick:

1. If `state.target_player_zdo == nil` or its `.mine == true` (we somehow gained ownership of the player ZDO, which would be a bug elsewhere — defensive check), drop aggro.
2. If `planar_distance(state.zdo.pos, state.target_player_zdo.pos) > state.aggro_radius * 1.5`, drop aggro.
3. Otherwise advance position one step toward `state.target_player_zdo.pos`.

### Player enumeration

Avledet exposes player ZDOs through the same `ZDOManager:get_zdos(filter)` we already use. Filter on `prefab and prefab.name == "Player"`. Cached once per aggro-scan call to avoid per-mob iteration cost.

```lua
local function snapshot_player_zdos()
    local players = {}
    local all = ZDOManager:get_zdos(function(zdo)
        return zdo.prefab and zdo.prefab.name == "Player"
    end)
    for _, z in ipairs(all) do players[#players + 1] = z end
    return players
end
```

Called once per aggro-scan tick (~1 Hz globally). For ~50 players × ~50 hostile mobs the worst case is 2,500 distance checks per second — negligible.

### Aggro-drop hysteresis

Aggro radius for each mob is the ENTRY threshold. The EXIT threshold is `aggro_radius × 1.5`. This avoids "flicker" near the boundary where a player oscillates between in/out of aggro.

Standard MMO pattern; matches what Valheim's vanilla AI roughly does.

## Mob registry extensions

Per-species, add `aggro_radius` and `hostile` (boolean):

| Species | speed | wander_radius | aggro_radius | hostile | Notes |
|---|---|---|---|---|---|
| Greydwarf | 1.5 | 4.0 | **12.0** | **true** | Phase 2 primary target — only proven hostile mob in registry |
| Boar | 1.2 | 4.0 | 0 | false | Passive in vanilla unless attacked. Aggro-on-damage is Phase 4. |
| Deer | 2.0 | 6.0 | 0 | false | Passive, flees in vanilla. Flee behaviour is Phase 5+. |
| Greyling | 1.0 | 3.0 | 0 | false | Passive. |
| Neck | 1.0 | 2.0 | 0 | false | Passive in vanilla; will sometimes attack from water. Defer. |

`hostile=false` mobs still get the registry entry but their `aggro_scan` no-ops, so the chase code is dead for them.

This means **Phase 2 only changes behaviour for Greydwarfs in the current registry.** That's intentional — keep the test surface small. Greyings/Boars/etc. will get hostile flags as we expand to more species.

## Implementation plan (parallelizable tasks)

| ID | Task | Files | Owner |
|---|---|---|---|
| **P2-A** | Extend `mob_registry.lua` with `aggro_radius` + `hostile` per species | `mob_registry.lua` | parallel agent |
| **P2-B** | Add `lib_vec.find_nearest(origin, candidates, max_distance)` returning `(zdo, distance)` or nil | `lib_vec.lua` | parallel agent |
| **P2-C** | Extend `stub_ai.lua` with `chasing` state, scan/lock/track/drop logic | `stub_ai.lua` | main session |
| **P2-D** | Live smoke test: walk toward a Greydwarf, observe pursuit, run away, observe drop | runtime | user-facing |

## Default per-mob behaviour params (additions)

In `stub_ai.lua` DEFAULTS:

```lua
aggro_scan_interval_seconds = 1.0  -- how often hostile mobs look for targets (matches tick interval)
aggro_drop_multiplier       = 1.5  -- exit threshold = aggro_radius × this
chase_step_interval_seconds = 0.25 -- chase ticks faster than idle/walk so movement looks smooth (4 Hz instead of 1 Hz)
```

The `chase_step_interval_seconds = 0.25` is a deliberate UX choice — at 1 Hz, a chasing mob would teleport in 1m increments per second, looking jerky. At 4 Hz with `speed * 0.25` step distances, movement looks roughly continuous on the client. This costs us 4× the per-mob CPU when chasing, but only hostile mobs that are actually in pursuit.

## Per-tick algorithm (tick_one extension)

```lua
local function tick_one(state, now)
    -- Determine effective tick interval (chase ticks 4x faster).
    local interval = state.state == "chasing"
        and DEFAULTS.chase_step_interval_seconds
        or  DEFAULTS.tick_interval_seconds
    if now - state.last_tick_at < interval then return end
    state.last_tick_at = now

    if not state.zdo.mine then M.release(state.zdo.id); return end

    local entry = registry.lookup(state.species)
    if entry and entry.hostile and entry.aggro_radius > 0 then
        -- Re-scan for a target (idle or walking → chasing transition)
        if state.state == "idle" or state.state == "walking" then
            local cur = state.zdo.pos
            local players = snapshot_player_zdos_cached(now)
            local target = lib_vec.find_nearest(cur, players, entry.aggro_radius)
            if target then
                state.state = "chasing"
                state.target_player_zdo = target
                return
            end
        end
    end

    if state.state == "chasing" then
        -- (chase tick body — drop checks + step toward target)
        ...
    end

    -- Existing idle/walking logic unchanged.
end
```

The `snapshot_player_zdos_cached(now)` memoizes the player list for the current tick across all mobs — one list, many readers.

## Smoke test (P2-D) success criteria

1. Boot Avledet with the Phase 2 bundle deployed.
2. Connect from a Windows client.
3. Find a Greydwarf (or wait for the Lua diag to log one in your area).
4. Walk toward it from ~20m away.
5. **Pass:** Within ~5 seconds of crossing the 12m boundary, the Greydwarf turns and walks toward you.
6. Run away to ~25m distance.
7. **Pass:** Within ~3 seconds of crossing the 18m drop boundary, the Greydwarf stops and goes idle.

Server-log telemetry to add (one-shot per state transition, not per tick):

```
[StubAI] Greydwarf zdo=<key> aggro on player <steam_id>
[StubAI] Greydwarf zdo=<key> drop aggro (out of range)
```

Quantitative: aggro/drop transitions per minute should be ≤ player_count × hostile_mobs_in_range. CPU should remain < 1% per Phase 1 baseline.

## Open questions / known unknowns

1. **Does `zdo.pos` return a stable reference across ticks for the player?** If sol2 returns a fresh Vec3f each access, our distance math is fine. If it caches and returns a stale snapshot, our chase target could be stuck. Phase 1 worked with this assumption for stationary positions — Phase 2 will validate dynamic.
2. **Player ZDO `prefab.name`.** We assume `"Player"`. Phase 1 diagnostic dump confirmed this for the connected player, but worth re-checking on first chase activation.
3. **Multiple Greydwarfs targeting the same player** is fine — they each pick "nearest player" independently and converge. No coordination needed.
4. **What happens if the player ZDO becomes invalid mid-chase?** (e.g., player force-quit, ZDO destroyed). Defensive `if not state.target_player_zdo or not state.target_player_zdo.pos` should handle it; we'd log and drop aggro.

## Estimated effort

- Spec drafting: 30 min (this doc)
- P2-A + P2-B (parallel agents): 30 min wall-clock
- P2-C (inline): 1-2 hours
- Smoke test + iteration: 1 hour
- **Total: 3-4 hours wall-clock** with parallelization, vs the 6-10 weeks I estimated solo without AI assistance in `ROADMAP.md`.

## After Phase 2

Phase 3 = pathfinder. The hardest single piece. Without a pathfinder, chasing mobs walk into walls. This affects the test feel even before Phase 4 (combat) lands. Suggest doing a small "pathfinder feasibility spike" right after Phase 2 ships, similar to the Avledet spike — answer "is heightmap-based A* viable in pure Lua" before committing to the 8-12 week phase 3 effort.
