--[[
    ServerAuthority — Phase 1: ZDO ownership transfer
    https://github.com/Sergentval/Avledet-ServerAuthority

    Port of the Sergentval/Valheim-serverside C# BepInEx mod's Phase 1 logic.
    Goal: when a peer disconnects, the server claims ownership of every
    non-Player ZDO it has visibility into, so mobs/items/structures don't
    freeze waiting for an absent owner.

    Vanilla Valheim's headless server runs Unity, which ticks BaseAI on
    server-owned ZDOs automatically. Avledet does NOT — it's a relay. So
    this Lua module gives us "no freeze on disconnect" but the entities
    won't actually do anything until Phase 1 (stub AI) ships. See ROADMAP.md.

    Three convergent paths into "claim a ZDO":
      Path B (primary): on Quit event, sweep all ZDOs once.
      Path C (backup): periodic sweep via PeriodicUpdate (3min default).
      Path A (deferred): per-ZDO claim at receive — tracked in Phase 1.5.
--]]

local SERVER_ID = Avledet.id

-- Player ZDOs are NEVER claimed by the server. Their owner is always
-- the actual player. Anything else is fair game (per category gating).
local function is_player(zdo)
    local prefab = zdo.prefab
    return prefab and prefab.name == "Player"
end

-- Walk every ZDO the server knows about. Claim non-Player non-server-owned
-- ones for the server.
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
        elseif is_player(zdo) then
            skipped_player = skipped_player + 1
        else
            zdo.owner = SERVER_ID
            claimed = claimed + 1
        end
    end

    print(string.format(
        "[ServerAuthority] %s — claimed %d / %d ZDOs (player=%d, already_server=%d)",
        reason, claimed, total, skipped_player, skipped_already_mine
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

print("[ServerAuthority] v0.1.0-alpha loaded. server_id=" .. tostring(SERVER_ID))
