# Phase 1 — Stub AI specification

**Status:** draft, gated on Phase 0 sustained-run report (2026-04-28).
**Implementer:** Sergentval + AI-assisted parallel sessions per the multi-agent workflow described in `docs/ROADMAP.md`.

## Goal

Make server-claimed mobs do *something* — specifically, idle-walk in a small radius — instead of freezing because no client owns them.

This is the smallest possible behavioural step that gives the project felt value over the BepInEx-mod path (`Sergentval/Valheim-serverside`). After Phase 1 ships:

- A player on the server can fight a Greydwarf, log out, and on reconnect find that mob still patrolling the area instead of frozen mid-animation.
- A second player exploring during the first player's absence sees a "living" world — mobs wander, world events fire, structures persist — even with zero clients connected continuously.
- We have not yet implemented combat, aggro, or pathfinding. Those are Phases 2–4.

**Phase 1 ships when:** dropping a mob ZDO into the world, having `ServerAuthority.lua` claim it, and observing the mob walk in `~3m` random circles for 2+ minutes without freezing or crashing — confirmed both via server-log telemetry and a connected client visually seeing the mob move.

## Out of scope for Phase 1

- Aggro / target detection (Phase 2)
- Mob → player pathing (Phase 2 + 3)
- Pathfinding around obstacles (Phase 3)
- Hit detection / damage (Phase 4)
- Per-mob personality (each species walks the same way for now; per-mob AI configs come in Phase 6)
- Tameable behaviour (Phase 5+)
- Sound / animation triggering (mostly client-driven; we just send position deltas)

## Architecture

### How the C++ side ticks today

Avledet's main loop (`IAvledet::update` in `library/src/Avledet.cpp:861`) runs roughly:

```
NetManager:Update()        # process incoming RPCs
ZDOManager:Update()        # housekeeping; flushes dirty ZDOs to peers
ZoneManager:Update()       # zone generation around peers
ScriptManager:update()     # ← fires Avledet's 'Update' event to all subscribed Lua scripts
sleep(1ms)
```

The loop's natural rate is ~hundreds of Hz, throttled by `sleep_for(1ms)` plus whatever the work in NetManager/ZDOManager takes.

### How Phase 1 hooks in

```lua
Avledet:subscribe('Update', function()
    tick_ai(Avledet.delta)     -- delta is float seconds since last tick
end)
```

`tick_ai` is responsible for:
1. Iterating server-owned mob ZDOs (a Lua table maintained as we claim and release).
2. Throttling each mob's AI to its configured tick rate (default 1Hz — i.e., decide on a new direction once per second).
3. Updating `zdo.pos` to reflect movement.
4. Letting Avledet's `ZDOManager:Update()` handle network flush automatically (we do NOT manually call `ForceSendZDO`; the dirty-tracker takes care of it).

### Module structure

Drop-in next to the existing `lua/scripts/ServerAuthority/ServerAuthority.lua`:

```
lua/scripts/ServerAuthority/
├── ServerAuthority.lua         # existing — claim logic
├── scriptInfo.yml              # existing
├── stub_ai.lua                 # NEW — main AI tick + per-mob state
├── mob_registry.lua            # NEW — list of mob prefabs we manage; expandable per phase
└── lib_vec.lua                 # NEW — Vec3f helpers (random unit vector, etc.)
```

`scriptInfo.yml` `entry: ServerAuthority` continues to point at `ServerAuthority.lua`, which `require()`s the others. (Or — if Avledet's sandboxed Lua doesn't expose `require`, we use the bundled-script path that worked for the C++ side: separate scripts per directory loaded by Avledet's mod manager. To be confirmed during implementation.)

## Data model — per-mob AI state

For each server-owned mob ZDO, maintain in a Lua table keyed by `ZDOID`:

| Field | Type | Purpose |
|---|---|---|
| `last_tick_at` | float (server-time seconds) | Throttle gate; only re-decide after `tick_interval` has passed |
| `target_pos` | Vec3f | Where the mob is currently walking toward |
| `state` | string | `idle` / `walking` / `arrived` |
| `state_until` | float | When to transition to next state (e.g., idle ends at this time) |
| `home_pos` | Vec3f | The ZDO's position when we first started managing it; bounds the wander radius |
| `species` | string | prefab name — informs species-specific defaults later |

We do NOT store this in the ZDO itself (Valheim ZDOs have a fixed schema; arbitrary fields would need network round-trips). Pure server-side state in our Lua table is fine — it's volatile across server restarts but Phase 1 doesn't need persistence (mobs return to home_pos = current_pos on restart, indistinguishable from "they came back to wander").

### Persistence note

For Phase 1, AI state is in-memory only. After a server restart, every server-owned mob restarts with `home_pos = current_pos`, `state = idle`. This is fine — players can't tell the difference. If we need persistence later (Phase 5+), Avledet's ZDO custom-fields API can store small amounts of per-ZDO data.

## Behaviour specification

### Default per-mob parameters

| Param | Default | Rationale |
|---|---|---|
| `tick_interval_seconds` | 1.0 | One AI decision per second is more than enough at human-perception scale |
| `wander_radius_meters` | 3.0 | Small enough that `home_pos` stays meaningful; visible movement at human scale |
| `walk_speed_meters_per_second` | 1.0 | Slow but visible. Real Valheim mob speeds vary 1.5–4 m/s; match per-species in Phase 6 |
| `idle_probability` | 0.30 | 30% of state transitions go to idle, 70% to walk |
| `idle_duration_seconds` | (2.0, 5.0) | Random in range |
| `arrival_threshold_meters` | 0.3 | Within this distance of `target_pos`, consider arrived |

### State machine per mob

```
        ┌─────┐    pick random target within wander_radius    ┌────────┐
        │idle │──────────────────────────────────────────────▶│walking │
        │     │                                                │        │
        └─────┘                                                └───┬────┘
           ▲                                                       │
           │              reached target_pos OR                    │
           │              state_until expired                      │
           └───────────────────────────────────────────────────────┘
```

Each tick, for each managed mob:

1. **If state is `walking`:**
   - Compute `delta = target_pos - current_pos`. If `|delta| < arrival_threshold`, transition to `idle` for a random 2–5 seconds.
   - Otherwise, advance `current_pos` by `(delta.normal * walk_speed * dt)`. Clamp to wander_radius from home.
   - Write `zdo.pos = current_pos`. Avledet's dirty tracker handles the broadcast.

2. **If state is `idle`:**
   - If `now < state_until`, do nothing.
   - Otherwise, with probability `idle_probability`, stay idle (pick new `state_until`). With remaining probability, transition to `walking` toward a fresh random `target_pos` chosen within `wander_radius` of `home_pos`.

3. **Always:** if `not zdo.mine` (we lost ownership somehow — e.g., a player connected and reclaimed it), drop it from the managed-mobs table.

### Throttling

We hook into `Update` (which fires every server tick, ~hundreds of Hz). Inside, we early-return if `now - last_tick_at < tick_interval`. Cheap, no scheduler needed.

### Y-axis (vertical) handling — known gap

Valheim entities live on a heightmap; their y-coord must match the ground. Our Phase 1 spec sets target_pos.x and .z randomly within wander_radius but leaves `.y` equal to the ZDO's current y. This is wrong if the mob is walking up/down a slope — they'll appear to clip through the ground or float.

**Decision for Phase 1:** ignore. Mobs will look slightly off on slopes, but the smoke test runs on flat-ish terrain and the Phase 0 sustained-run validation revealed players accept some visual oddness on idle mobs.

**Phase 1.5 (small):** add heightmap-y query. The 4 critical-unknowns research found Avledet's `HeightmapManager` can sample y by (x,z); we just need a Lua binding for `GetHeight`. ~30 LOC C++ + Lua bind.

## Mob registry

Phase 1 ships with a curated list of mobs we will manage. Anything not in the list, even if server-owned, is left alone (so e.g. boats / structures we already claim don't get walked around).

Initial mob list (chosen for diversity and low-risk):

```lua
-- mob_registry.lua
return {
    Boar       = { speed = 1.2, wander_radius = 4.0 },
    Deer       = { speed = 2.0, wander_radius = 6.0 },
    Greyling   = { speed = 1.0, wander_radius = 3.0 },
    Greydwarf  = { speed = 1.5, wander_radius = 4.0 },
    Neck       = { speed = 1.0, wander_radius = 2.0 },
}
```

Trolls, Drakes, Serpents, etc. are excluded from Phase 1 — they're complicated (large, fly, swim) and we want the simplest possible scope first.

## Integration with `ServerAuthority.lua`

Today's `reclaim_non_player_zdos` claims everything non-Player. Phase 1 adds a side effect: **on claim, register the ZDO with the AI manager if its prefab is in the mob registry.**

```lua
-- in reclaim_non_player_zdos, after `zdo.owner = SERVER_ID`:
local prefab_name = zdo.prefab and zdo.prefab.name or nil
if prefab_name and mob_registry[prefab_name] then
    stub_ai.manage(zdo, prefab_name)
end
```

Reverse path — when a peer reconnects and Vanilla reclaims a ZDO from the server, we need to **release** it from our manager. Hook into the `ZDOUnpacked` event (already fires per-ZDO when a peer sends data) and check `not zdo.mine` to detect ownership flips, then drop from manager.

## Success criteria for Phase 1

The smoke test that proves Phase 1 = done:

1. **Boot** Avledet with the new Lua modules.
2. **Connect** from a Windows client; spawn a Greydwarf via console (`F5` → `imacheater` → `spawn Greydwarf`).
3. **Disconnect** the client.
4. **Server log** shows `[ServerAuthority] Quit(...) — claimed N ZDOs` (existing Phase 0 behaviour) AND new `[StubAI] now managing N mobs (Greydwarf=1, ...)`.
5. **Reconnect** within 2 minutes.
6. **Visually:** the Greydwarf is in a different position than where you left it, having walked roughly within a 4m circle of where you last fought it.
7. **Server log** shows no errors, no Lua sol-runtime exceptions, RAM growth still bounded (consistent with Phase 0's ~0.5 MB/min legitimate ZDO heap).

Quantitative: managing 5 mobs, AI tick budget per second should be < 1ms of CPU on the server (we're doing trivial vec math). Confirm via `ps -p <pid> -o pcpu` showing no measurable jump.

## Implementation plan (parallelizable tasks)

These tasks are independent and can be assigned to different parallel sessions:

| ID | Task | Owner | Depends on |
|---|---|---|---|
| **P1-A** | Implement `lib_vec.lua` — random unit vector, distance, normalize | parallel | — |
| **P1-B** | Implement `mob_registry.lua` — initial 5-mob table | parallel | — |
| **P1-C** | Implement `stub_ai.lua` — manage/release/tick functions per spec above | main session | P1-A, P1-B |
| **P1-D** | Wire `ServerAuthority.lua` to call into `stub_ai.manage` on claim | main session | P1-C |
| **P1-E** | Smoke test on running Avledet — drop a mob, observe behaviour | user-facing | P1-D |
| **P1-F** | Add lightweight Lua tests under `tests/` for state-machine logic | parallel | P1-C |

P1-A, P1-B, P1-F are trivially parallelizable to a `gsd:fast` agent or background subagent. P1-C is the meaty one and stays in the main session.

## Open questions

- **Does Avledet's sandboxed Lua expose `require()`?** The bundled `Commands` script tried `require` and failed with "attempt to call a nil value (global 'require')". We may need to inline everything into one file, or use Avledet's `dofile`-equivalent.
- **Does `subscribe('Update', ...)` work?** Confirmed by code reading — `Events::Update` is fired in `Avledet.cpp:898`. But the Phase 1 first build will be the first runtime confirmation.
- **Position writes in `Update` — is the dirty-tracker robust to high-frequency updates?** Avledet's `ZDOManager:Update` runs every tick and batches dirty ZDOs. We tick AI at 1Hz so this is well below any reasonable threshold, but worth monitoring.

## Estimated effort

- Pure design & code: 4–8 hours (parallelizable down to ~4 hours wall-clock with 2 sessions)
- Smoke test + bug-fixes: 2–4 hours
- **Total: 1–2 days** with the multi-agent workflow, vs the 4-8 weeks I'd estimated solo without AI assistance.

Once Phase 1 lands, Phase 2 (aggro + chase) becomes the next planning target.
