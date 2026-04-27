# Phase 3 — Pathfinder specification

**Status:** spec, ready for parallel implementation.
**Predecessor:** [`PHASE-2-SPEC.md`](./PHASE-2-SPEC.md) + [`PHASE-2-5-SPEC.md`](./PHASE-2-5-SPEC.md). Phase 2.5 (server-owned ZDO stickiness) shipped as `v0.2.5-aggro-chase` 2026-04-27 — chase is real, but mobs walk in straight lines and clip through terrain/walls.

## Goal

Replace straight-line chase movement with intelligent pathfinding so server-driven mobs walk *around* obstacles instead of through them. Specifically:

- Greydwarfs chasing a player navigate around trees/rocks/buildings rather than clipping
- Movement smoothly follows ground contour (no flying or sinking)
- Path quality is "good enough that the player can't tell server-side AI from vanilla client AI" — not perfect, just believable

After Phase 3 ships:

- Server-side aggro chasing feels like normal Valheim AI from the player's perspective
- This is a hard prerequisite for Phase 4 (combat) — combat needs mobs to actually reach the player to swing
- Pathfinder is reusable for future phases (patrol routes, fleeing, mob-mob interactions)

## Out of scope for Phase 3

- Complex tactical AI (flanking, group coordination)
- Smell/sound-based path planning (e.g., mobs following blood trails)
- Long-distance pathing > 100m (mobs would never realistically chase that far)
- Vertical pathing through dungeons (interior nav is its own feature)
- Path dynamic update on world changes (player builds a wall mid-chase) — recompute on the next path-tick, don't try to be smart

## The big architectural choice

**Heightmap-grid A*** vs **navmesh** vs **steering behaviors**.

| Approach | Effort | Quality | Performance | Vanilla-similarity |
|---|---|---|---|---|
| **Heightmap A*** | Medium | Good | Tractable in Lua | Closest to vanilla |
| **Navmesh** | High | Excellent | Best at runtime | Vanilla doesn't use one — would diverge |
| **Steering** | Low | Mediocre | Best | Visibly different from vanilla |

**Decision: heightmap A***. Avledet's heightmap is the only authoritative terrain data we have, and vanilla Valheim's mob AI uses similar grid-based reasoning (Unity NavMesh under the hood, but driven by similar terrain data). Going with steering would visibly diverge; navmesh would be a multi-month rewrite.

## Phase 3 has a Phase 3.0 prerequisite

**Avledet's heightmap is not exposed to Lua** today. Audit confirmed:

```
grep "HeightmapManager" library/src/API*.cpp  →  no bindings
```

`Heightmap::GetHeight(x, z) → float` exists in C++ (see `library/src/Heightmap.cpp:85+`) but has no `sol::usertype` registration. Same for `IsBuildable` and similar primitives.

**Phase 3.0 (prerequisite):** expose a minimal Lua API for heightmap queries. Similar surgical pattern as Phase 2.5: ~20 lines of C++ added to `library/src/API.cpp`.

```cpp
// Pseudocode of what Phase 3.0 adds
this->new_usertype<IHeightmapManager>("IHeightmapManager",
    sol::no_constructor,
    "get_height_at",   &IHeightmapManager::GetHeightAt,    // Vec3f → float
    "is_buildable_at", &IHeightmapManager::IsBuildableAt,  // Vec3f → bool
);
env["HeightmapManager"] = HeightmapManager();
```

(Exact method names TBD — the C++ side needs a thin facade because the existing `IHeightmapManager::GetHeightmap(point)` returns a Heightmap& which we'd need to also expose. A facade `GetHeightAt(point)` that does the lookup internally is cleaner.)

## Architecture

### Path data structures

```lua
-- A path is an ordered list of waypoints. The first is current pos,
-- the last is target. Path is consumed waypoint-by-waypoint as the
-- mob advances.
local Path = {
    waypoints = {},     -- list of Vec3f
    next_index = 1,     -- which waypoint we're moving toward right now
    target_zdo = nil,   -- (optional) ZDO the path was computed against
    computed_at = 0,    -- timestamp; used to expire stale paths
    valid = true,       -- false if a waypoint is now unreachable (recompute)
}
```

### A* implementation

Lua A* on a 1m grid, sampled lazily from the heightmap:

- **Origin:** the chasing mob's current position (snapped to grid)
- **Goal:** the player's current position (snapped to grid)
- **Neighbors:** 8 cardinal+diagonal neighbors on the grid
- **Cost:** Euclidean distance × terrain factor (water = 5×, lava = ∞ for blockers, hill steepness = 1.0–3.0×)
- **Heuristic:** Euclidean distance to goal
- **Bound:** max 200 nodes searched; if not found, fall back to straight line

Ground walkability:
- Heightmap query at (x, z) → terrain y
- Compare to neighbour cell y — slope > ~45° = blocked
- IsBuildable check excludes water, lava
- Nearby structure ZDOs (queried from ZDOManager:get_zdos with prefix-filter "piece_/wood_/stone_") expand to ~1.5m occupancy radius

### Caching

Naive: recompute every chase tick (4 Hz × N chasing mobs). For 5 chasing mobs at 4 Hz that's 20 A*/sec. Each A* up to 200 nodes. Fine in Lua.

Better: cache last path per mob. Recompute only if:
- Player moved > 5m since path was computed
- Path is older than 2 seconds
- Mob is closer to a later waypoint than to the current one (we passed a waypoint)

This drops typical recomputes to 1-2/sec/mob.

### Smoothing

Raw A* on a grid produces zigzag paths. Standard fix: line-of-sight collapse — for each pair of adjacent waypoints, if the straight line between them is walkable, drop the intermediate waypoints. ~1 LOC pattern, big visual improvement.

### Y-axis (vertical) handling — finally fixed

Phase 1 spec deferred Y-axis to "Phase 1.5". Phase 3.0's heightmap query naturally fixes this — when stepping toward a waypoint, set `next_pos.y = HeightmapManager:get_height_at(next_pos.x, next_pos.z)`. Mobs follow ground contour automatically.

This is the **other major reason** to do Phase 3.0 even before any A* — it's the proper fix for the "mobs fly or clip" issue from the Phase 2.5 smoke test.

## Implementation plan

| ID | Task | Files | Owner |
|---|---|---|---|
| **P3-0a** | Add C++ HeightmapManager Lua binding (GetHeightAt, IsBuildableAt facade) | Avledet `library/src/API.cpp` (+ header tweaks) | main |
| **P3-0b** | Rebuild Avledet, redeploy, smoke-test that `HeightmapManager:get_height_at(Vec3f.new(0,0,0))` returns a float from Lua | Avledet | main |
| **P3-0c** | In `lib_vec.lua`, replace `advance_toward` to call `HeightmapManager:get_height_at` for the resulting position's y. Mobs immediately stop flying/clipping vertically | `lib_vec.lua` | parallel |
| **P3-A** | Implement `pathfinder.lua` with A* + bounded search + heuristic + cost function | new file | main |
| **P3-B** | Implement `pathfinder.compute_path(origin, goal, max_nodes)` returning a Path object | `pathfinder.lua` | main |
| **P3-C** | Path smoothing via line-of-sight collapse | `pathfinder.lua` | parallel |
| **P3-D** | Integrate into `stub_ai.lua` chase: replace `advance_toward(state.zdo.pos, target_pos)` with `pathfinder.next_waypoint(state)`. Cache invalidation rules per spec. | `stub_ai.lua` | main |
| **P3-E** | Smoke test: chase a Greydwarf around a tree — should walk around, not through. Build a wall, chase from across it — should detour. | live | user |

## Smoke test (P3-E) success criteria

1. Boot Avledet with Phase 3.0 binding + Phase 3 Lua deployed.
2. Stand in front of a tree. Have a server-claimed Greydwarf at 10m, with the tree directly between you. (Diagnostic dump shows ZDO IDs to identify the right one.)
3. **Pass:** Greydwarf walks AROUND the tree, not through it. Path detour adds ~1-2 seconds vs straight line.
4. Build a 4m wall (place a few wood walls in front of the Greydwarf).
5. **Pass:** Greydwarf detours around the wall to reach you, doesn't clip through it.
6. Run uphill 30°.
7. **Pass:** Greydwarf follows up the hill, y-coord matches terrain, doesn't fly.
8. **Pass:** No `tick error` lines. No noticeable framedrop or CPU spike.

Quantitative: with 10 simultaneously chasing mobs, server CPU usage stays < 5%. (Baseline Phase 2: ~14% CPU during heavy ticks. Adding pathfinding ~10% on top is acceptable.)

## Open questions / known unknowns

1. **What's the heightmap resolution?** Avledet's heightmap is "per zone", and zones are 64×64 m by default. Per-zone heightmap is probably 65×65 height samples = 1m resolution. If it's coarser (e.g. 4m), our 1m grid gets noisy. Phase 3.0 audit will confirm.
2. **Structure-collision queries from Lua.** We can iterate `ZDOManager:get_zdos` filtered by prefix, but that's O(N) per A* expansion — too slow. Need a spatial index, or pre-bake structure positions into a per-zone grid mask. Phase 3 may need a Phase 3.0b: expose a "is this point blocked by a structure?" C++ helper.
3. **Pathfinder Lua perf.** A* with 200-node bound × 4 Hz × 10 mobs = 8000 ops/sec of node expansion + heap operations. Lua is ~50–100× slower than native C++. Realistic budget: 1-2 ms per A* call. If we exceed this, drop to bounded-fallback (straight line) more aggressively.
4. **Path corridor smoothing.** Beyond line-of-sight collapse, we may want corridor smoothing (B-spline through waypoints). Defer unless A* zigzag is visually painful.
5. **Recompute on world change.** If a player builds a wall mid-chase, our cached path becomes stale. Easy fix: invalidate path on next chase tick. Smarter fix: subscribe to "ZDO created near zone X" events. Defer to Phase 3.5 unless proven necessary.

## Estimated effort

- Phase 3.0 (C++ heightmap binding): 1–2 hours including rebuild
- P3-A + P3-B (A* core): 4–6 hours wall-clock with parallel agents
- P3-C (smoothing): 1–2 hours
- P3-D (stub_ai integration): 2–3 hours
- P3-E (smoke test + iteration): 2–4 hours
- **Total: 1–2 days** with multi-agent dispatch.

The estimate assumes the heightmap query works as expected on first try. If the heightmap resolution is coarser than 1m or the API doesn't have a clean facade, P3-0 expands by ~half a day.

## After Phase 3

Phase 4 = combat resolution (mob-side). Phase 3's pathfinder lets mobs reach the player; Phase 4 lets them swing. With both, server-side AI is functionally complete for hostile mobs at the "MVP" level. Phase 5 (status/stagger/ragdoll) and Phase 6 (per-mob configs) are polish.

If Phase 3 finds the heightmap-Lua bridge is the wrong abstraction (too slow, too coarse), the alternative is to do pathfinding entirely in C++ as another Avledet patch. That's a much larger effort (3-4 weeks rather than 1-2 days), so we go Lua-first.
