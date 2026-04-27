# Prior art & engine limits research — 2026-04-26

## TL;DR

- **`ddormer/valheim-serverside` is not "abandoned-because-it-hit-a-wall" — it was actively maintained through Oct 2025 and only marked unmaintained in a README edit on 2026-03-29 with no technical post-mortem.** It worked, shipped against patch 0.220.5, and its main known failure mode is OOM on dedicated servers running large modpacks (issue [#104](https://github.com/ddormer/valheim-serverside/issues/104)) — not a fundamental architectural ceiling. Successor naming is explicitly invited.
- **`Smoothbrain/DedicatedServer` (blaxxun-boop, last push 2026-01-16) already implements an arguably cleaner version of our Phase 1** via a `ZDO.SetOwner`/`SetOwnerInternal` Prefix that flips any zero-uid assignment to the server session-id. Our sweep is more defensive but covers the same ground.
- **Phase 2 (server-side AI tick) is already partially shipped by `ValheimPerformanceOverhaul` v3.0.0** — "Smart Zone Ownership" auto-transfers AI control to the lowest-ping client and "Smart ZDO Sorting" prioritises players/portals/ships over AI in network sync. It does *not* run AI on the dedicated server; it just routes AI ownership to a fast client. This is a real signal: the community is treating server-side AI as expensive enough that even a perf-focused mod chose not to run it on the server.
- **Engine reality**: ZDO sync is ~20 Hz (50 ms tick), each "active" entity sends full-state per tick, the historical `m_dataPerSec=64KB/s` cap was raised to ~10240 sendQueueSize in 0.148.6 but bandwidth still dominates over CPU at 50 player counts. There is no public IronGate statement endorsing or forbidding server-authoritative mods; the official cap is 10 players and Iron Gate has no stated roadmap to change it.
- **A from-scratch C++/OS-language reimplementation already exists** (`ricosolana/Avledet`, ~952 commits, last release May 2023, "documentation lacking, ZDO IDs make proxying not really feasible") and a 2021-era VaLNGOS group chasing 1000-player MMO has gone quiet (homepage now reads as a generic blog). Pragmatic ceiling for a BepInEx mod looks like the 64-150 players "Comfy Valheim" demonstrably hosts.

**Recommendation in one line:** Phase 2 should be re-scoped from "tick AI on the dedicated server" to "guarantee server keeps ZDO ownership, then let the game's existing AI tick run on the server thread that already exists for owned ZDOs" — that's what every successful predecessor actually did, and the patch surface is dramatically smaller than a custom AI tick.

## 1. `ddormer/valheim-serverside` post-mortem

**What it did.** A BepInEx plugin that intercepts the client/server ZDO ownership model so the dedicated server is the simulation owner of terrain, monsters, and most objects. The implementation is a focused set of Harmony patches in [`Features/Core.cs`](https://github.com/ddormer/valheim-serverside/blob/main/src/Valheim_Serverside/Features/Core.cs):

- `ZNetScene.CreateDestroyObjects` Prefix — enumerate every connected peer, union their sector objects, then call original `CreateObjects` / `RemoveObjects`. Solves the fact that the vanilla code only spawns objects around `ZNet.GetReferencePosition()` which is meaningless on a headless server.
- `ZoneSystem.IsActiveAreaLoaded` / `ZoneSystem.Update` — same trick, generate Local-Zones for every peer position so the server simulates them.
- `ZDOMan.ReleaseNearbyZDOS` — full reimplementation: if a ZDO has no owner *and* a peer is nearby, server claims it; if the current owner is leaving and no peer is nearby, release.
- `RandEventSystem.FixedUpdate` and `SpawnSystem.UpdateSpawning` transpilers — patch out the `Player.m_localPlayer != null` guard so events and spawners run on the headless server.
- `ZNetScene.OutsideActiveArea` — return false if any peer can see the point. Critical for `BonePileSpawner` and similar.
- `ZRoutedRpc.RouteRPC` — special-case ship "RequestRespons" so ship driver gets latency-free local control.

**Why it died.** The README explicitly says: *"As of 2026, this project is no longer maintained. If you release your own version of this mod, we kindly request that you use a different name for it."* Commit history shows the README change happened 2026-03-29 ([commits](https://github.com/ddormer/valheim-serverside/commits/main)) — there was no preceding "I give up" issue, no architectural blocker called out, and the maintainer was still triaging crash reports as recently as Jan 2026 ([#104 comment](https://github.com/ddormer/valheim-serverside/issues/104)).

**The real failure modes (from issues):**
- **OOM on heavy modpacks** ([#104](https://github.com/ddormer/valheim-serverside/issues/104)): a server with 12 GB RAM was OOM-killed with rss=6.5 GB and reserved=14 GB. The maintainer's hypothesis was that the mod plus other content mods adds enough world objects to blow the budget. No definitive memory-leak smoking gun.
- **Mod conflicts** are the #1 source of issues: `Smoothbrain-CombatOwner` ([#115](https://github.com/ddormer/valheim-serverside/issues/115)) breaks damage application; ValheimPlus needed an explicit compat shim ([#113](https://github.com/ddormer/valheim-serverside/issues/113), and the only PR-driven fix in 2025 was `Update ValheimPlus compatibility (GetNearbyChests)` on 2025-10-01); Marketplace mod's territory rules silently break ([#117](https://github.com/ddormer/valheim-serverside/issues/117), Nov 2025).
- **Physics anomalies under load** ([#115](https://github.com/ddormer/valheim-serverside/issues/115)): a karve floating 10 m in the air under serpent attack; creature damage failing to register on first hit. Reporter speculates this mirrors client-side latency problems but inverted (creatures now experience the latency that clients used to).

**What we should learn:**
1. The mod did *not* "hit a wall" — it shipped, worked, and survived multiple Valheim patches. Abandonment looks like maintainer fatigue, not technical infeasibility.
2. The hardest bug class is **mod-vs-mod ownership conflicts** (CombatOwner, Marketplace, Smart Zone Ownership). Any successor must publish a clear ownership-precedence story or it will eat the same triage cost.
3. **Memory, not CPU, is the ceiling people actually hit.** Plan for it: bound caches, instrument allocations, surface live ZDO counts.
4. ddormer's design relies on `ZNet.IsServer()` and per-peer sector iteration; our sweep-based design is independent of that and survives even if a peer is mid-disconnect — that's a real correctness win and worth keeping.

## 2. Mod ecosystem map

| Mod | Scope | Conflicts with our work? | Dependency candidate? |
|---|---|---|---|
| **denikson/BepInExPack_Valheim** ([source](https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/)) | BepInEx 5.4.23.3 preconfigured; sets `Game.isModded=true` after chainload; ships console-enabled config. | No, it's the substrate. | **Yes — already the dep.** Pin to an explicit version. |
| **Valheim-Modding/Jotunn** ([repo](https://github.com/Valheim-Modding/Jotunn), v2.29.0 Apr 2026) | Content-creation library: custom items, prefabs, locations, UI, recipes; managers for commands/skills/localization. Provides `ConfigSync` and a mod registry. **No ZDO-ownership or AI-tick abstractions.** | No — orthogonal scope. | **Optional**. We don't add content; only worth taking on for `ConfigSync` (saves writing it). Adds a hard dep on Jötunn updates. Recommend: skip for Phase 2; reconsider when we add user-facing UI. |
| **Grantapher/ValheimPlus** ([repo](https://github.com/Grantapher/ValheimPlus), 0.9.17.1 Feb 2026) | Massive QoL bundle: difficulty/spawn scaling, item despawn, projectile tuning, version enforcement, ConfigSync. **Does not change ZDO ownership or run server-side AI.** Touches `SpawnSystem` parameters. | **Soft conflict on `SpawnSystem` if we patch it.** ddormer needed an explicit `Compat_ValheimPlus` feature module. | No. Treat as a target for compatibility testing, not a dep. Document explicit `[BepInIncompatibility]` if behaviours diverge. |
| **WackyMole/WackysDatabase** ([repo](https://github.com/Wacky-Mole/WackysDatabase)) | YAML-driven content authoring: items, recipes, creature cloning, materials. ConfigSync. | None — pure data layer. | No. |
| **blaxxun-boop / Smoothbrain DedicatedServer** ([repo](https://github.com/blaxxun-boop/DedicatedServer), 1.0.2, last push 2026-01-16) | **The most direct competitor to our Phase 1.** Patches `ZDO.SetOwner` & `SetOwnerInternal` Prefix — any `uid==0` write becomes server-session-id. Also patches `ZDO.Load` Postfix to claim unowned ZDOs at load. Patches `ZDOMan.IsInPeerActiveArea` so server is "always in active area". Reimplements `ZDOMan.FindSectorObjects` to union all peer sectors. Transpiles `SpawnSystem.UpdateSpawning`. **`[BepInIncompatibility]` with ValheimPlus declared in code.** | **Direct overlap with Phase 1.** Their mechanism is more elegant (Prefix on `SetOwner` itself catches every reassignment at the source); our sweep is broader and survives missed paths. | **No — competitor, but study its patch sites.** We should reference its `SetOwner` Prefix as a Path D candidate; it's strictly narrower than our sweep but ~100× cheaper per call. |
| **mvp/Serverside_Simulations** (referenced [Thunderstore link](https://new.thunderstore.io/c/valheim/p/mvp/Serverside_Simulations/) in search results) | Believed to be a fork/republish of ddormer's mod. Not verified — Thunderstore profile returned 404 at time of writing. | Same scope as ddormer. | No. |
| **Skarif/ValheimPerformanceOverhaul** ([Thunderstore](https://thunderstore.io/c/valheim/p/Skarif/ValheimPerformanceOverhaul/), v3.0.0, ~7600 dl) | Smart ZDO Sorting (priority: players > portals > ships > AI in sync queue). **Smart Zone Ownership: auto-transfers AI ownership to lowest-ping client in the zone.** Decor mesh batching. Light/smoke/animator caches. Adaptive throttling for >400 ms peers. Both server- and client-side. Closed-source on Thunderstore; GitHub repo not found. | **Direct conflict if we ship Phase 2 as "tick AI on server"** — VPO actively pushes AI ownership to clients. Either we displace VPO, or we co-exist by ensuring our server claim wins on persistent ZDOs while letting VPO route transient AI. | No (closed source). Crucial benchmark for "what the perf-aware community thinks is the right answer." |
| **Smoothbrain/CombatOwner** ([Thunderstore](https://thunderstore.io/c/valheim/p/Smoothbrain/CombatOwner/)) | Switches creature ZDO owner to the player it's attacking, so parry/dodge feel local. Client-side only. | **Will fight our claim aggressively** — every aggro tick re-targets the owner. Reporter in ddormer #115 confirms damage breaks when CombatOwner is active. Must be either explicitly incompatible-flagged or our claim must skip combat-active creatures. | No. |
| **Smoothbrain/SmartZoneOwnership** | Mentioned in search results as transferring AI control to lowest-ping player. Thunderstore page 404'd; may be folded into VPO or renamed. | Same conflict shape as VPO + CombatOwner. | No. |
| **JereKuusela/Server_devcommands**, **JereKuusela/Render_Limits**, **Digitalroot/Heightmap_Unlimited_Remake** | Server admin and render-limit tools; widely used alongside ddormer. | None known. | No. |
| **redseiko/ComfyMods** ([repo](https://github.com/redseiko/ComfyMods)) | ~70 small mods powering the Comfy Valheim 64-player server: portals, ladders, signs, chat, loading screens. **No server-authority mod in the set.** They run vanilla networking; they just add UX. | None. | No, but it's evidence that the largest production server in the wild is *not* using server-authoritative simulation. |

Net verdict for the table: **the only dependency candidate beyond BepInExPack is none.** Jötunn buys us `ConfigSync`; we already have BepInEx's config system. Stay lean.

## 3. Engine reality

**Unity loop & headless mode.** Valheim is built on Unity 2020-era. The dedicated server runs the same `assembly_valheim.dll` as the client; "headless" means no rendering, no audio, but **all `Update`/`FixedUpdate` MonoBehaviours run** — that's why ddormer must transpile out `Player.m_localPlayer != null` guards in `RandEventSystem.FixedUpdate` and `SpawnSystem.UpdateSpawning`. The headless server is fundamentally just a client with no local player.

**Tick model.** Network sync runs at ~20 Hz (50 ms). Each "active" entity (movable, owned by a peer) sends its full ZDO position+rotation per tick — there is no delta encoding. This is the well-known reason Valheim doesn't scale: bandwidth grows linearly with active-entity count *per peer in earshot*, and the original `m_dataPerSec=64KB/s` cap was the bottleneck. In patch 0.148.6 the field was removed and replaced with a hard-coded `sendQueueSize=10240` (up from 3072) — roughly 3× the headroom but still capped (see james-a-chambers' [Revisiting Fixing Valheim Lag](https://jamesachambers.com/revisiting-fixing-valheim-lag-modifying-send-receive-limits/)).

**ZDO ownership semantics.** `ZDO.GetOwner()` returns a `long` peer-id. `0` means unowned. `ZDOMan.GetSessionID()` returns the server's id. Owners are reassigned in `ZDOMan.ReleaseNearbyZDOS` based on which peer is in the ZDO's sector. The server has its own session-id that can own ZDOs (this is what we use). Importantly, `ZNet.GetReferencePosition()` returns garbage on dedicated servers — every server-side simulation mod has to either patch around that or enumerate peers manually.

**Performance walls (community-observed):**
- Vanilla 10-player cap is "deliberate Iron Gate design choice — networking does some peer-to-peer lifting that doesn't scale past that" (consensus in ddormer issue threads & PCGamer/Wikipedia coverage).
- Comfy Valheim demonstrably runs **64 players steady, 152 peak** (their site claims [largest server in the world](https://www.comfyvalheimserver.com/)) without server-authoritative sim — they tune bandwidth, run a custom mod stack, but ZDO ownership stays distributed.
- Heavy bases are the actual perf killer: every placed piece is a ZDO; F2 in-game shows instance count; >50k instances is where things start to stutter.
- 50-player + thousands-of-structures target is plausible **only with bandwidth headroom (raised limits) and aggressive piece-sleeping** — not from server-authority alone.

**No public IronGate statement on server-authority modding.** Their official position is that modding "is not officially supported, done at your own risk, no guarantee for future compatibility." No tweets, blog posts, or roadmap items endorse, forbid, or mention server-side simulation mods. They have not announced any plans to raise the 10-player cap.

## 4. Server-side AI feasibility (Phase 2 specific)

**How `MonsterAI`/`BaseAI` ownership check works.** `BaseAI` is the parent; `MonsterAI` extends it. Both subclass `MonoBehaviour`. The relevant pseudocode pattern (from how every dedicated-server mod patches it):

```
// BaseAI.UpdateAI / MonsterAI.UpdateAI — called from Update/FixedUpdate
if (m_nview == null || !m_nview.IsValid()) return;
if (!m_nview.IsOwner()) return;  // <-- THE GATE
// ... actual AI: pathfinding, target selection, attack
```

`ZNetView.IsOwner()` returns `m_zdo.GetOwner() == ZDOMan.GetMyID()`. So **AI runs on whichever peer owns the underlying ZDO**. The dedicated server *can* tick AI for any ZDO it owns — no special patch needed at the AI layer; the `IsOwner()` check passes for free.

**This means our Phase 2 may not need any AI-layer patching at all** — if Phase 1 (server claims ZDO ownership) is correct and stable, AI ticks on the server automatically. This matches what ddormer's mod actually does: there is no `MonsterAI` patch in `Features/Core.cs`. The simulation moves to the server *because* ownership moves to the server.

**Patch sites that *would* be needed if we want explicit server-AI tick:**
- `Player.m_localPlayer != null` guards inside spawn/event systems (transpiler — done by ddormer & Smoothbrain).
- `ZNet.GetReferencePosition()` callers that drive zone activation (must enumerate peers — done by ddormer).
- `ZNetScene.OutsideActiveArea(Vector3)` — must return false for any peer's active area, not just the local player's (done by ddormer).
- Possibly `BaseAI.SetAlerted` and `BaseAI.HaveTarget` — but only for behaviour tweaks, not for getting AI to run at all.

**Known traps:**
1. **`CombatOwner`-class mods will fight our ownership.** Server claims a draugr; player engages; CombatOwner reassigns to the player; server reclaims on next sweep; AI stutters between ticks. We need to either (a) detect and skip ZDOs that have a recent combat-owner timestamp, or (b) declare `[BepInIncompatibility]`.
2. **`Smart Zone Ownership` (VPO) is doing the *opposite* thing** — actively pushing AI ownership *to* clients for latency. Two valid strategies: ours (bandwidth/cheating wins) vs theirs (latency/feel wins). They are not reconcilable without a deliberate "scope split" config.
3. **Memory growth on the server is real and unbounded** (ddormer #104). Every ZDO the server owns is held resident; piece counts in built-up bases hit 50k+ rapidly. Any Phase 2 must include `Diagnostics` for live ZDO count, sweep latency, and per-category counts.
4. **`m_localPlayer` null guards are pervasive.** Random events, spawners, and several minor systems all gate on `Player.m_localPlayer != null` and need IL transpilers. ddormer's transpilers are good reference material.
5. **Boss fights, ship physics, and serpent/karve interactions** are the most-reported visual breakages on serverside-sim mods (ddormer #115). Ship physics are deliberately kept client-side by ddormer for steering responsiveness — we should preserve that exception.

## 5. IronGate signals

**No direct quoted statements on server-authority were found** in the time available. The strongest evidence on Iron Gate's stance is structural:

- The official 10-player cap has held since launch (Feb 2021 → Apr 2026, five years, multiple major patches including 0.220.5 "Bog Witch" and 0.221.x "Call to Arms"). [Valheim Wikipedia entry](https://en.wikipedia.org/wiki/Valheim).
- The 0.148.6 patch (mid-2023) **removed** `m_dataPerSec` from `ZDOMan` and silently changed the bandwidth model (3072 → ~10240 sendQueue) — community network mods broke ([ValheimPlus #422](https://github.com/valheimPlus/ValheimPlus/issues/422)). Read as: Iron Gate is willing to refactor networking internals without announcement, and has made deliberate increases to bandwidth headroom — but only modestly.
- The official [Valheim FAQ](https://www.valheimgame.com/faq/) and [server guide](https://valheim.com/support/a-guide-to-dedicated-servers/) describe the dedicated server as not running game logic — clients are authoritative on their assigned regions. This is a documented architectural choice, not a bug.
- Modding posture: **"not officially supported"** is the consistent line; no public denouncement of mods like ddormer/serverside; no takedowns.

**Inference.** Iron Gate isn't going to fix this themselves and isn't going to stop us. They will, however, refactor `ZDOMan` and `ZNet` internals on their own schedule; any mod must plan for breakage every major patch.

## 6. Comparable game forks

- **`ricosolana/Avledet`** ([repo](https://github.com/ricosolana/Avledet)): from-scratch C++ Valheim server. ~952 commits, last release v1.0.5 May 2023. C++ + Lua scripting. Self-described as "documentation lacking and outdated"; replay system is incomplete; explicitly states **"Bungee-like proxying is not really feasible due to ID constraints"** — meaning the ZDO ID space is centralized enough that you can't trivially shard one world across multiple server processes. **Existence proof that protocol-level reimplementation is doable solo for ~3 years; status proof that it doesn't reach production-feature parity.**
- **VaLNGOS** (Valheim Large Network Game Object Server Suite): 2021 announcement of a 1000-player MMO server "from-scratch open source", team incl. ex-MaNGOS WoW devs, used "specialized programming languages designed for writing operating systems." Coverage in [PCGamer](https://www.pcgamer.com/modders-want-to-turn-valheim-into-a-1000-player-mmo/), [PCGamesN](https://www.pcgamesn.com/valheim/mod-mmo), [MassivelyOP](https://massivelyop.com/2021/04/23/valheim-could-be-modded-into-a-1000-player-mmorpg/). [valngos.com](https://valngos.com/) today is a generic blog about scalable multiplayer; no public GitHub for VaLNGOS itself surfaces in search. **Likely outcome: stalled.**
- **Comfy Valheim** ([site](https://www.comfyvalheimserver.com/), mods at [redseiko/ComfyMods](https://github.com/redseiko/ComfyMods)): the largest *currently-running* Valheim community server, 64 concurrent / 152 peak. Architecture: vanilla networking + bandwidth tuning + a curated mod stack of ~70 small UX/QoL mods. **Does not use server-authoritative simulation.** They get scale from network tuning and player discipline, not architecture changes. This is the most important data point in the section.
- **Rust → uMod/Oxide** (formerly Oxide): a plugin framework for the official Facepunch Rust dedicated server, not a reimplementation. Facepunch's TOS restricts modding to "admin tools only" — no reimplementation tradition. ([uMod Rust API](https://umod.org/documentation/games/rust)).
- **Conan Exiles, 7 Days to Die**: no community-developed server reimplementations or emulators surfaced in search. Both ship official dedicated server binaries that are extensible only via configuration and mod loaders, not replacement.
- **WoW MaNGOS / TrinityCore / CMaNGOS**: classic example of a *successful* full-rewrite emulator. Took 15+ years of community labour. Used as a reference team for VaLNGOS, possibly explaining VaLNGOS's optimism.

**Lesson from comparables:** the 64-player ceiling reachable with mod-stack tuning is *much* easier to hit than the 1000-player ceiling reachable only by from-scratch rewrite. Avledet shows the rewrite is a multi-year project; VaLNGOS shows the public announcement of one usually doesn't ship. The mod path is the only one that's actually delivered repeatedly.

## 7. Recommendation for Phase 2

**Phase 2 should *not* be "tick AI on the server" as a new system.** It should be **"prove that Phase 1's ownership is correct and stable enough that vanilla AI ticks on the server *because* the server owns the ZDO."** That reframing is supported by sections 1, 2, and 4: ddormer/serverside has no `MonsterAI` patch, and Smoothbrain/DedicatedServer's only AI-related patch is the spawn-system `m_localPlayer` transpiler. **If Phase 1 is right, Phase 2 is mostly free.**

Concrete actions for Phase 2:

1. **Add a "Path D" (`ZDO.SetOwner`/`SetOwnerInternal` Prefix)** modeled on Smoothbrain/DedicatedServer's pattern. It catches every reassignment at the source for ~zero CPU cost and makes our sweep a defence-in-depth backup rather than the primary mechanism. (Section 2 row, Section 4 traps.)
2. **Patch the `Player.m_localPlayer != null` guards** in `RandEventSystem.FixedUpdate` and `SpawnSystem.UpdateSpawning` (use ddormer's transpilers as reference, MIT-compat license). Without these, server-owned monsters won't get into combat states correctly because random events and spawners still no-op on headless. (Section 4 patch sites.)
3. **Patch `ZNetScene.OutsideActiveArea(Vector3)`** to return false if *any* peer is in range. Required for `BonePileSpawner` and similar ambient spawners. (Section 4.)
4. **Add live diagnostics**: per-tick sweep latency, total server-owned ZDO count, ZDO count by category, allocation rate. The dominant failure mode in the predecessor mod was OOM, and it was hard to diagnose because there were no metrics. (Section 1 lesson #3.)
5. **Declare explicit `[BepInIncompatibility]` for `org.bepinex.plugins.valheim_plus`** (matches Smoothbrain/DedicatedServer's pragmatic choice) and document the runtime behaviour in the presence of `Smoothbrain-CombatOwner` and `Skarif/ValheimPerformanceOverhaul` (`Smart Zone Ownership`). The ownership war between us and these mods is the #1 issue source for ddormer; we should not rediscover it. (Section 1 failure modes, Section 2.)
6. **Do *not* depend on Jötunn or any content library.** It enlarges our update surface for zero benefit at this scope. (Section 2.)

**On the longer-term mod-vs-fork decision (out-of-scope but the research touches it):** the data argues strongly for "stay a mod." Avledet shows a 3-year solo rewrite that hasn't shipped. VaLNGOS shows a multi-FAANG-engineer rewrite that went silent. Comfy Valheim shows that the most-scaled production server in the wild *did not* take the rewrite path. The realistic ceiling for a polished mod stack is somewhere between Comfy's 64 demonstrated and the 100ish that bandwidth/CPU budgets allow if we land Phase 1 + Phase 2 + ValheimPerformanceOverhaul-style tuning. That gets you "MMO-feeling" without forking.

If a fork is ever justified, it's specifically to unlock the 100→1000 player range, and the *first* prerequisite is solving ZDO-ID centralization (Avledet's stated wall — Section 6). That's a research project, not a Phase 3.

## Sources

- [github.com/ddormer/valheim-serverside](https://github.com/ddormer/valheim-serverside) — README, [issues](https://github.com/ddormer/valheim-serverside/issues), [commits](https://github.com/ddormer/valheim-serverside/commits/main), [Features/Core.cs](https://github.com/ddormer/valheim-serverside/blob/main/src/Valheim_Serverside/Features/Core.cs)
- [ddormer #104 OOM investigation](https://github.com/ddormer/valheim-serverside/issues/104)
- [ddormer #115 general notes (physics & damage anomalies)](https://github.com/ddormer/valheim-serverside/issues/115)
- [ddormer #116 changelog mismatch](https://github.com/ddormer/valheim-serverside/issues/116)
- [ddormer #117 Marketplace mod conflict](https://github.com/ddormer/valheim-serverside/issues/117)
- [github.com/blaxxun-boop/DedicatedServer](https://github.com/blaxxun-boop/DedicatedServer) — Smoothbrain DedicatedServer source
- [github.com/Valheim-Modding/Jotunn](https://github.com/Valheim-Modding/Jotunn)
- [github.com/Grantapher/ValheimPlus](https://github.com/Grantapher/ValheimPlus)
- [ValheimPlus issue #422 — 0.148.6 m_dataPerSec break](https://github.com/valheimPlus/ValheimPlus/issues/422)
- [github.com/Wacky-Mole/WackysDatabase](https://github.com/Wacky-Mole/WackysDatabase)
- [Thunderstore: BepInExPack_Valheim](https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/)
- [Thunderstore: Skarif/ValheimPerformanceOverhaul](https://thunderstore.io/c/valheim/p/Skarif/ValheimPerformanceOverhaul/) and [changelog](https://thunderstore.io/c/valheim/p/Skarif/ValheimPerformanceOverhaul/changelog/)
- [Thunderstore: Smoothbrain/CombatOwner](https://thunderstore.io/c/valheim/p/Smoothbrain/CombatOwner/)
- [Thunderstore: Smoothbrain/DedicatedServer](https://thunderstore.io/c/valheim/p/Smoothbrain/DedicatedServer/)
- [github.com/ricosolana/Avledet](https://github.com/ricosolana/Avledet) — Valheim server in C++
- [github.com/redseiko/ComfyMods](https://github.com/redseiko/ComfyMods)
- [Comfy Valheim Server homepage](https://www.comfyvalheimserver.com/)
- [PCGamer: Modders want to turn Valheim into a 1000-player MMO](https://www.pcgamer.com/modders-want-to-turn-valheim-into-a-1000-player-mmo/)
- [PCGamesN: Valheim 1000-player MMO mod](https://www.pcgamesn.com/valheim/mod-mmo)
- [MassivelyOP: Valheim 1000-player MMORPG mod](https://massivelyop.com/2021/04/23/valheim-could-be-modded-into-a-1000-player-mmorpg/)
- [valngos.com](https://valngos.com/) (now a generic blog)
- [james-a-chambers: Fixing Valheim Dedicated Server Lag](https://jamesachambers.com/fixing-valheim-dedicated-server-lag-modify-send-receive-limits/) and [Revisiting](https://jamesachambers.com/revisiting-fixing-valheim-lag-modifying-send-receive-limits/)
- [Valheim FAQ (irongate)](https://www.valheimgame.com/faq/)
- [Valheim dedicated server official guide](https://valheim.com/support/a-guide-to-dedicated-servers/)
- [Valheim Wikipedia](https://en.wikipedia.org/wiki/Valheim)
- [uMod Rust API documentation](https://umod.org/documentation/games/rust)
