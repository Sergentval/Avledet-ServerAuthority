# Roadmap

Phase 0 → 6, end goal: server-authoritative Valheim that feels like an MMO.

Each phase ships something usable on its own. The project can stop at any phase boundary and the shipped phases still deliver value.

## Phase 0 — Foundation

Make the platform real, prove the architecture, set up sustainable workflow.

- [ ] Create repo, scaffold, README
- [ ] Port `Sergentval/Valheim-serverside` Phase 1 (ZDO ownership transfer on disconnect) to Lua
- [ ] Drop the Lua module into Avledet, smoke-test the same DisconnectPatch flow we validated in C# — confirm `claimed N ZDOs after peer removal` behaviour reproduces in Avledet
- [ ] Avledet upstream PRs: bit_cast fix, GCC 13 warning suppressions, TRACY_ON_DEMAND default
- [ ] Avledet running as a systemd service for sustained-run validation
- [ ] 24h sustained run with no leaks, periodic auto-reconnect script
- [ ] 4 critical-unknowns research (raycasts, pathfinding, animation, prediction) — gate Phase 1 commitment

**Done when:** Lua port is shipping, server is stable for 24h, Phase 1 unknowns resolved.

## Phase 1 — Stub AI

Make server-claimed mobs idle-walk instead of freezing. This alone is a major step over what `Valheim-serverside` (C# BepInEx mod) delivers.

- [ ] Lua per-mob registration (`Sweeper` claims any non-player ZDO; the "stub AI" Lua coroutine ticks each owned mob)
- [ ] Random idle-walk in 3m radius, 30% time idling
- [ ] No combat, no aggro, no chase
- [ ] Per-mob velocity caps (Greyling slow, Drake-not-flying placeholder, etc.)
- [ ] Network: position updates flushed via Avledet's ZDO replication (free, no custom protocol)
- [ ] Smoke test: disconnect from a mob mid-fight → mob keeps wandering instead of freezing

**Done when:** disconnecting from a Greydwarf doesn't freeze it; it idle-walks until you reconnect.

## Phase 2 — Aggro + chase

Mobs detect players in range, walk toward them. No damage yet.

- [ ] Aggro radius per mob (Boar 8m, Troll 20m, Drake 50m)
- [ ] Target selection (nearest player by default)
- [ ] Movement toward target (straight-line; pathfinder is Phase 3)
- [ ] Aggro-drop on target out of range or LOS lost (LOS still naïve in this phase — Phase 3 fixes)
- [ ] Smoke test: walk past a mob → it follows. Walk far enough away → it gives up.

**Done when:** mobs visibly notice and follow players without combat resolution.

## Phase 3 — Custom pathfinder

The hardest piece. Mobs need to walk around obstacles instead of straight through them.

- [ ] Read Avledet's `HeightmapManager` data layout — confirm A* feasibility (research from Phase 0 informs)
- [ ] A* implementation in Lua over a 1m-grid sampled from the heightmap
- [ ] Cache paths per-zone for warm reuse
- [ ] Avoid water (drown), lava (death), placed structures (collision)
- [ ] Movement smoothing so paths look natural at low tick rate
- [ ] Smoke test: place a wall between you and a Boar; it walks around.

**Done when:** mobs navigate forests, around player buildings, and across reasonable terrain without getting stuck.

## Phase 4 — Combat resolution

Server-side hit detection + damage. The big one.

- [ ] Hit detection: animation-timing approximation from prefab metadata + raycast at swing peak
- [ ] Damage calculation matching vanilla Valheim's formulas (armour, stagger, weakness/resistance)
- [ ] Mob-to-mob friendly fire toggle
- [ ] Death + drop spawn
- [ ] Player-vs-mob, mob-vs-mob, mob-vs-structure (Trolls smashing walls)
- [ ] Smoke test: full combat cycle with no client validating hits

**Done when:** combat completes without any client-side authority.

## Phase 5 — Polish

Status effects, stagger, knockback, ragdoll, taming, breeding.

Estimated cost: 4–8 weeks. Lots of corner cases.

## Phase 6 — Per-mob configs

Every creature has its own personality. Highly parallel work — one agent per mob type.

50+ creatures × ~few-hundred-LOC config each.

This phase runs **in parallel** with Phases 1–5; mobs gradually get their unique behaviours layered on top of the framework.

## Stopping points

- **After Phase 0:** the platform is real and the architecture is validated. Work resumes when ready.
- **After Phase 1:** delivers "mobs don't freeze on disconnect" — the original `ServerAuthority` goal but at MMO-scale player counts and structure counts.
- **After Phase 3:** delivers "intelligent NPC movement" — useful for builder/RP servers.
- **After Phase 4:** server-authoritative combat — the WoW-comparable point.
- **After Phase 5+6:** feature parity with vanilla Valheim AI.

The realistic path is Phase 0+1 in 2–3 months, then re-evaluate based on community traction and project's role.
