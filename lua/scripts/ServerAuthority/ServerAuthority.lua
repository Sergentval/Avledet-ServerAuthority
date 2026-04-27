--[[
    ServerAuthority — Phase 1 entry script
    https://github.com/Sergentval/Avledet-ServerAuthority

    NOTE: this file is the ENTRY POINT and assumes lib_vec, mob_registry,
    and stub_ai have been concatenated above it by the deploy bundle (see
    tools/bundle.sh). When the bundle runs:

        local lib_vec = (function() ...lib_vec.lua body... end)()
        local mob_registry = (function() ...mob_registry.lua body... end)()
        local stub_ai = (function() ...stub_ai.lua body... end)()
        -- THIS file's content follows --

    For local development without the bundler, use tools/bundle.sh to
    produce dist/ServerAuthority.lua before deploying. See deploy/README.md.

    Architecture:
      - Path B (primary): on Quit event, sweep all ZDOs once
      - Path C (backup):  periodic sweep via PeriodicUpdate (3min)
      - Stub AI:          server-claimed mobs idle-walk via Avledet's Update tick
--]]

local SERVER_ID = Avledet.id

-- Wire stub AI to the support modules. lib_vec and mob_registry are
-- captured from the IIFE locals in the bundled output.
stub_ai.init(lib_vec, mob_registry)

-- Player ZDOs are NEVER claimed by the server. Their owner is always
-- the actual player. Anything else is fair game (per category gating).
local function is_player(zdo)
    local prefab = zdo.prefab
    return prefab and prefab.name == "Player"
end

-- Try to register a newly-claimed ZDO with the stub AI manager.
-- Silently no-ops if the prefab isn't in the mob registry (we still
-- own the ZDO, we just don't run AI on it — items, structures, etc).
local function register_with_ai_if_mob(zdo)
    local prefab = zdo.prefab
    if not prefab then return end
    stub_ai.manage(zdo, prefab.name)
end

-- Walk every ZDO the server knows about. Claim non-Player non-server-owned
-- ones for the server, and register mobs with the stub AI manager.
--
-- Avledet's ZDOManager:get_zdos() requires at least one filter argument; there's
-- no no-arg "all ZDOs" overload. We use the Filter callback variant, which
-- sol2 binds from a Lua function. Returning true keeps the ZDO; we then
-- decide what to do with it in the loop.
local function reclaim_non_player_zdos(reason)
    local claimed = 0
    local skipped_player = 0
    local skipped_already_mine = 0
    local total = 0

    local all_zdos = ZDOManager:get_zdos(function(zdo) return true end)

    for _, zdo in ipairs(all_zdos) do
        total = total + 1

        if zdo.mine then
            skipped_already_mine = skipped_already_mine + 1
            -- Even if we already owned it, the manager may not be tracking
            -- it yet (e.g., we restarted while a mob was server-owned).
            register_with_ai_if_mob(zdo)
        elseif is_player(zdo) then
            skipped_player = skipped_player + 1
        else
            zdo.owner = SERVER_ID
            claimed = claimed + 1
            register_with_ai_if_mob(zdo)
        end
    end

    print(string.format(
        "[ServerAuthority] %s — claimed %d / %d ZDOs (player=%d, already_server=%d, ai_managed=%d)",
        reason, claimed, total, skipped_player, skipped_already_mine, stub_ai.count()
    ))
end

-- Path B: on every peer disconnect, run a one-shot recovery sweep.
-- This is the primary correctness path — guarantees server owns
-- everything left behind by the departing player.
Avledet:subscribe('Quit', function(peer)
    reclaim_non_player_zdos(string.format("Quit(%s)", peer.socket.host))
end)

-- Path C: backup periodic sweep. PeriodicUpdate fires every 3 minutes
-- by default — coarser than the C# mod's 5s sweep but acceptable as a
-- safety net since Path B catches the common case.
Avledet:subscribe('PeriodicUpdate', function()
    reclaim_non_player_zdos("PeriodicSweep")
end)

-- Activate the stub AI tick loop.
stub_ai.subscribe()

print("[ServerAuthority] v0.2.0-alpha (stub-ai) loaded. server_id=" .. tostring(SERVER_ID))
