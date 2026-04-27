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

    -- DIAGNOSTIC (Phase 1.5): collect unique prefab names with counts so we
    -- can see Avledet's actual naming convention. Will help fix the
    -- "registry says Boar but actual prefab is Boar(Clone) or similar" gap.
    local prefab_counts = {}

    local all_zdos = ZDOManager:get_zdos(function(zdo) return true end)

    for _, zdo in ipairs(all_zdos) do
        total = total + 1

        local name = zdo.prefab and zdo.prefab.name
        if name and name ~= "" then
            prefab_counts[name] = (prefab_counts[name] or 0) + 1
        end

        if zdo.mine then
            skipped_already_mine = skipped_already_mine + 1
            register_with_ai_if_mob(zdo)
        elseif is_player(zdo) then
            skipped_player = skipped_player + 1
        else
            zdo.owner = SERVER_ID
            claimed = claimed + 1
            register_with_ai_if_mob(zdo)
        end
    end

    -- Sort prefab counts and log the top 30. One-shot diagnostic.
    local sorted = {}
    for n, c in pairs(prefab_counts) do sorted[#sorted + 1] = { name = n, count = c } end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local out = {}
    for i = 1, math.min(30, #sorted) do
        out[#out + 1] = string.format("%s=%d", sorted[i].name, sorted[i].count)
    end
    print("[ServerAuthority/diag] top 30 prefabs in last sweep: " .. table.concat(out, " "))

    -- Also flag any name that looks like a known mob species but doesn't
    -- match the registry — these are the ones Phase 1.5 needs to handle.
    local mob_keywords = { "oar", "eer", "reyling", "reydwarf", "eck",
                           "oblin", "roll", "kele", "raugr", "urtling",
                           "olf", "ox", "ish", "rake", "erpent" }
    local suspects = {}
    for _, e in ipairs(sorted) do
        for _, kw in ipairs(mob_keywords) do
            if e.name:lower():find(kw) then
                suspects[#suspects + 1] = string.format("%s=%d", e.name, e.count)
                break
            end
        end
    end
    if #suspects > 0 then
        print("[ServerAuthority/diag] mob-shaped names: " .. table.concat(suspects, " "))
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
