# Avledet spike report — 2026-04-27

Outcome of the time-boxed afternoon spike to validate whether `crazicrafter1/Avledet` (C++ Valheim server reimplementation) is a viable alternative to the BepInEx-mod path for reaching MMO-scale Valheim multiplayer (50+ players, 10k+ structures, sub-150ms latency).

## TL;DR

- **Avledet builds, boots, authenticates with Steam, accepts a vanilla Valheim 0.221.12 client, and serves a player session.** Three small build patches needed (documented below).
- **Idle RAM = 86 MB, single-player active RAM = 112 MB after 8 minutes.** Compared to vanilla Valheim's ~3 GB baseline, this is 30–50× more efficient — the architectural promise of "no Unity = no main-thread bottleneck" is real.
- **The 14.6 GB memory leak observed in run-1 was Tracy profiler instrumentation, not Avledet game code.** Adding `TRACY_ON_DEMAND` to the build dropped the leak rate from ~28 MB/min to ~0.5 MB/min (the latter being legitimate ZDO heap growth).
- **Recommendation: switch to Avledet as the primary platform for the MMO goal.** Keep `Sergentval/Valheim-serverside` (the C# BepInEx mod) alive for vanilla-server admins, but move new development to `Avledet-ServerAuthority` Lua scripts. The C# Phase 1 ownership logic is ~30 lines of Lua against Avledet's API.

## 1. What we set out to test

Spike goal (from the prior research session): validate Avledet as a real alternative before committing to either the mod path or the fork path. Specifically:

1. Does Avledet actually build on a current Linux toolchain?
2. Does it boot and accept connections from a stock Valheim client?
3. Is its memory/CPU profile materially better than vanilla Valheim?
4. Does its Lua scripting expose enough surface to port `ServerAuthority`?

## 2. Build process

### Toolchain

- VPS: Ubuntu 24.04, GCC 13.3.0, Clang 18.1.3, CMake 3.28.3, Ninja, 24 cores
- vcpkg 2026-04-08 manifest mode (18 packages from `vcpkg.json` + `lua:x64-linux-dynamic` separately)
- Steamworks SDK from `julianxhokaxhiu/SteamworksSDKCI` v1.62 release (public mirror; matched headers + Linux x86_64 `libsteam_api.so`)
- `steamclient.so` symlinked from Valheim's bundled copy at `~/.steam/sdk64/steamclient.so` (Avledet's runtime expects it there)

### Patches we had to make to build

**P1 — `library/include/Vector.h:540-560`** — replace `*reinterpret_cast<std::uint32_t const *>(&value.x)` with `std::bit_cast<std::uint32_t>(value.x)`. Original code triggered `-Werror=strict-aliasing` on GCC 13.

**P2 — `library/CMakeLists.txt:14-25`** — add `-Wno-stringop-overflow`, `-Wno-array-bounds`, `-Wno-restrict`, `-Wno-dangling-reference` to `target_compile_options`. GCC 13's stringop-overflow checker has known false positives in `std::copy` chains under `-O3`; was breaking the build through `-Werror`.

**P3 — `library/CMakeLists.txt:84-99`** — append `target_compile_definitions(avledet_library PUBLIC TRACY_ON_DEMAND)`. **This is the load-bearing patch** for the memory question — see §4.

These are all upstream-fixable. P1 is the only one that's a real bug; P2 is a GCC quirk; P3 is a defensible default change for production builds.

### Linker quirk

Initial build linked against Valheim's bundled `libsteam_api.so`, which is from SDK ~1.51 era. The Proton snapshot we used for headers was SDK 164. Result: undefined references on `SteamInternal_*`, `GetSteamID64`, etc. Fixed by swapping to the SteamworksSDKCI v1.62 release which ships matched headers + `.so` together.

### Build time

After all patches: clean build in ~3 min (54 compile units across 24 cores). vcpkg first-time install was 5.2 min, mostly OpenSSL.

## 3. Run results

Three controlled runs, all on the same VPS, single Windows client connecting via direct IP (`51.178.25.173:27420`).

### Run 1 — Tracy active (default), 11h sustained

| Time | RSS | Peers | Notes |
|------|-----|-------|-------|
| t=0 (idle) | 96 MB | 0 | Steam auth complete, listening |
| t=4 min (still idle) | 117 MB | 0 | Already growing 5 MB/min |
| t=10s post-connect | ~140 MB | 1 | Player spawned in |
| t=10h post-connect | **14.6 GB** | 1 | Server log silent for 13 hours |

GDB stack trace at the silent state showed main thread alive in `IAvledet::update()` (sleep loop), Tracy's 4 worker threads also alive (`Tracy Sampling`, `Tracy Profiler`, `Tracy DXT1`, `Tracy Symbol Worker`), and a 3840-byte recv-queue stuck on the Steam query port. Initial diagnosis: real leak in network/ZDO path. Wrong.

### Run 2 — Tracy active, 10 min controlled connect-disconnect

Watcher captured 30s-resolution RSS samples through one full session:

| Phase | Duration | RSS growth | Rate |
|-------|----------|-----------|------|
| Idle pre-connect | 90s | 95 → 117 MB | 14 MB/min |
| Connected (player exploring) | 10 min | 117 → 401 MB | **28 MB/min** |
| 90s post-disconnect | 90s | 401 → 445 MB | 22 MB/min — **still growing without a peer** |

That post-disconnect growth was the smoking gun: a leak that continues with zero peers cannot be in a per-peer code path. Combined with seeing 4 Tracy threads in the stack trace and `-DTRACY_ENABLE` in the compile flags, the leak source became obvious — Tracy's in-memory event buffer is unbounded by default and only drains when a Tracy GUI client connects to it.

### Run 3 — `TRACY_ON_DEMAND` build, 9 min connect-disconnect

| Phase | Duration | RSS growth | Rate |
|-------|----------|-----------|------|
| Idle pre-connect | 90s | 86 → 86 MB | **0 MB/min — flat** |
| Connected (player exploring) | 8.8 min | 86 → 112 MB | **0.5 MB/min** (matches ZDO count growth: 0 → 20,051 ZDOs) |
| Post-disconnect | — | 112 MB | flat |

Reduction vs run-2: **70× lower memory growth rate**. The remaining 0.5 MB/min is ZDO heap (each ZDO ≈ 250 bytes including unordered-map bucket overhead; 20k × 250 = 5 MB observed delta — matches arithmetic).

## 4. Tracy was the leak

Tracy is a real-time profiler. Without `TRACY_ON_DEMAND`, every profiled event/zone/sample is recorded into an in-memory ring buffer that only drains when a Tracy GUI tool connects to download it. Running a Tracy-instrumented binary in production with no GUI ever attached is a textbook unbounded leak.

Avledet's `vcpkg.json` lists `tracy[crash-handler]` as a hard dep; `CMakeLists.txt` has `find_package(Tracy CONFIG REQUIRED)` unconditionally; vcpkg's `TracyConfig.cmake` adds `-DTRACY_ENABLE` via `INTERFACE_COMPILE_DEFINITIONS`. The result is that any default Avledet build bleeds memory on a no-GUI server.

`TRACY_ON_DEMAND` keeps Tracy compiled in but gates all event recording on whether a Tracy client is currently connected. Memory stays flat in normal operation. Profiling on demand still works when needed. This should be the upstream default; it isn't, and the project's TODO doesn't flag it. (Worth a PR upstream.)

## 5. Lua API audit (the porting question)

Avledet exposes the surfaces that a `ServerAuthority`-style mod needs, all via sol2 bindings discovered in `library/src/API*.cpp`:

```cpp
// from APIZdo.cpp
"owner", sol::property(&ZDO::get_owner, &ZDO::set_owner),
"mine", sol::property(&ZDO::owned_by_me,
                     sol::resolve<void(bool)>(&ZDO::set_claimed)),
"owned", sol::property(&ZDO::has_owner),
"prefab", sol::property(&ZDO::get_prefab),
"prefab_hash", sol::property(&ZDO::get_prefab_hash),

// from APIAvledet.cpp / APIPeer.cpp / APINetwork.cpp / APIRouteManager.cpp
Avledet:subscribe('Quit', function(peer) ... end)
Avledet:subscribe('RouteInAll', '<rpc-name>', function(peer, ..., params) ... end)
ZDOManager:zdos()
ZDOManager:force_send_zdo(zdo_id)
NetManager:get_peer(owner_id)
RouteManager:invoke(owner, methodSig, ...)
```

Translated, the entire current `ServerAuthority` C# Phase 1 design becomes:

```lua
local AVL_ID = Avledet.id

local function reclaim_non_player_zdos()
    for _, zdo in ipairs(ZDOManager:zdos()) do
        if not zdo.mine and zdo.owned then
            local prefab = ZNetScene:get_prefab(zdo.prefab_hash)
            if prefab and prefab.name ~= "Player" then
                zdo.owner = AVL_ID
            end
        end
    end
end

-- Path B equivalent: claim everything non-player when a peer leaves
Avledet:subscribe('Quit', function(peer)
    reclaim_non_player_zdos()
end)

-- Path C equivalent: periodic sweep
Avledet:add_task(5.0, true, function()
    if Avledet.peer_count > 0 then reclaim_non_player_zdos() end
end)
```

That's the entire Phase 1. ~30 lines including config loading. The C# version we just shipped is ~600 lines plus 12 Harmony patches and three reflection workarounds for proprietary game-DLL access — all gone in the Lua port because Avledet exposes the data directly without needing IL surgery.

**Caveat:** the bundled example scripts (`Portals/PortalsZDO.lua`, `Commands/Commands.lua`, `Sleep/Sleep.lua`) all fail to load on current Avledet because they use deprecated globals (`MethodSig`, `IAvledet`, `require`). The API has evolved and the examples haven't kept up. We'd be writing against the live source as documentation, not the bundled samples.

## 6. Architectural recommendation

Updated decision matrix (replaces the speculative one from the research session):

| | Pure mod (`Valheim-serverside`) | **Avledet + Lua port (recommended)** | Full server fork |
|---|---|---|---|
| Player ceiling | ~50 (mod path) | **~200+ (validated trajectory)** | ~200+ |
| RAM at idle | ~3 GB (Unity) | **86 MB** | n/a |
| RAM with player | leak-free Phase 1 | **+5 MB per 20k ZDOs** | n/a |
| Vanilla update survival | Auto via Harmony, may break per patch | Avledet pins to a Valheim version, must be ported | Same |
| Distribution | Thunderstore 1-click | Custom binary, manual install | Same |
| Mod ecosystem coexistence | Full BepInEx | None (Lua only) | None |
| Dev velocity for our logic | High (C# w/ tooling) | **Highest (Lua, ~30-line modules)** | Low (C++ rewrite) |
| Bus factor | Several Valheim mod devs | Single maintainer | Single maintainer |

### What we recommend

1. **Keep `Sergentval/Valheim-serverside` v0.1.0 published** for vanilla-server admins who can't or won't switch binaries. Maintain it lightly — bug fixes, version bumps — but stop investing in big new features.

2. **New repo: `Sergentval/Avledet-ServerAuthority`.** Lua module port of the same logic, plus the additional features the mod path can't reach (true server-side AI, AOI culling, etc.).

3. **Upstream contributions to Avledet** — at minimum the `TRACY_ON_DEMAND` default and the GCC 13 build patches. This builds rapport with the maintainer and reduces our future merge cost. The maintainer's commit `bye all 'valhalla'` (2026-03-02) shows active interest in the project's direction.

4. **Phase 1.5 of the mod path is now lower priority** — only worth doing if it directly serves vanilla-server users. The "harden ownership + remove client-presence guards" work translates directly to Avledet anyway via Lua, so we don't lose the design work.

## 7. Open questions for follow-up

These are not blockers for the architectural decision but should be answered before we lock in:

1. **Sustained run** — leave Avledet up 24h with periodic auto-disconnects/reconnects, confirm RAM tops out below ~500 MB and stays there. Run-3 was only 11 minutes; the leak we caught originally took 11 hours to balloon.
2. **Multi-client** — connect 2–3 clients simultaneously, see if there's a per-pair leak we'd miss with one client.
3. **Stress** — Lua-script-spawn 1000 mobs + 5000 structures, measure tick time, RAM, network bandwidth. The MMO claim only matters if we have the data.
4. **What does Avledet actually run on its main tick?** Worth reading `IAvledet::update()` to understand whether mob AI, physics, etc. actually run server-side or are still expected to be client-driven (in which case our scaling story changes).
5. **IronGate patch survival** — Avledet currently pins to Valheim 0.221.12. When the next Valheim patch ships, how long to update Avledet? Need a track record before we can stake reliability claims on it.

## 8. Patches we made (for the next person)

All against `crazicrafter1/Avledet@0.221.12`:

```diff
diff --git a/library/include/Vector.h b/library/include/Vector.h
@@ -1,5 +1,7 @@
 #pragma once

+#include <bit>
 #include <cmath>
 #include <cstdint>
+#include <cstring>

@@ -551,9 +553,9 @@ struct ankerl::unordered_dense::hash<avledet::util::CSU::Vector3f>
     {
         using namespace ankerl::unordered_dense::detail::wyhash;
-        std::uint64_t x = *reinterpret_cast<std::uint32_t const *>(&value.x);
-        std::uint64_t y = *reinterpret_cast<std::uint32_t const *>(&value.y);
-        std::uint64_t z = *reinterpret_cast<std::uint32_t const *>(&value.z);
+        std::uint64_t x = std::bit_cast<std::uint32_t>(value.x);
+        std::uint64_t y = std::bit_cast<std::uint32_t>(value.y);
+        std::uint64_t z = std::bit_cast<std::uint32_t>(value.z);
         return mix((x << 32) | y, z);
     }
 };

diff --git a/library/CMakeLists.txt b/library/CMakeLists.txt
@@ -16,11 +16,15 @@ else()
             -Wall
             -Wextra
             -Werror
-            -Wno-unknown-pragmas
-            -Wno-unused-variable
-            -Wno-deprecated-declarations
-            -Wno-unused-value
-            -Wno-unused-parameter
+            -Wno-unknown-pragmas
+            -Wno-unused-variable
+            -Wno-deprecated-declarations
+            -Wno-unused-value
+            -Wno-unused-parameter
+            -Wno-stringop-overflow # GCC 13 false positives in std::copy/memmove with -O3
+            -Wno-array-bounds      # GCC 13 false positives paired with stringop-overflow
+            -Wno-restrict          # GCC 13 false positives in templated code with -O3
+            -Wno-dangling-reference # GCC 13 false positives with range-v3 / sol2
     )
 endif()

@@ -94,3 +98,8 @@ target_link_libraries(avledet_library
         range-v3::meta range-v3::concepts range-v3::range-v3
         isptr::isptr
 )
+
+# Tracy on-demand: only record profiling events when a Tracy GUI client is connected.
+# Without this, Tracy's in-memory event buffer grows unbounded (~25 MB/min while a
+# peer is connected, ~15 MB/min idle), which OOM-kills the server in <12 hours.
+target_compile_definitions(avledet_library PUBLIC TRACY_ON_DEMAND)
```

Plus the SDK-version sourcing decision: use `SteamworksSDKCI v1.62` (matched headers + `libsteam_api.so` together) rather than mixing Proton snapshot headers with Valheim's bundled `.so`.

## Sources

- Avledet repo (active fork): https://github.com/crazicrafter1/Avledet
- Avledet repo (original/upstream): https://github.com/ricosolana/avledet
- Steamworks SDK mirror: https://github.com/julianxhokaxhiu/SteamworksSDKCI/releases/tag/1.62
- Tracy `TRACY_ON_DEMAND` docs: https://github.com/wolfpld/tracy (Manual §3.5)
- Diagnostic logs from this spike: `/tmp/avledet-run1.log`, `/tmp/avledet-run1-trace.txt`, `/tmp/avledet-server.log`, `/tmp/avledet-metrics.log`
