-- mob_registry.lua — Phase 1 curated list of mob prefabs the stub AI manages.
-- ZDOs whose prefab is not in this table are left alone, even if server-owned.
-- See docs/PHASE-1-SPEC.md ("Mob registry"). Tick/idle defaults live in stub_ai.lua.

local M = {}

-- Per-species behaviour parameters.
-- aggro_radius: meters within which a hostile mob locks onto the nearest player.
--   0 means no scan ever fires (passive mob; chase code is dead for it).
-- hostile: when false, the mob stays on Phase 1 idle-walk behaviour and the
--   aggro/chase logic in stub_ai.lua no-ops regardless of aggro_radius.
-- See docs/PHASE-2-SPEC.md ("Mob registry extensions") for the source table.
M.entries = {
    Boar      = { speed = 1.2, wander_radius = 4.0, aggro_radius = 0,    hostile = false },
    Deer      = { speed = 2.0, wander_radius = 6.0, aggro_radius = 0,    hostile = false },
    Greyling  = { speed = 1.0, wander_radius = 3.0, aggro_radius = 0,    hostile = false },
    Greydwarf = { speed = 1.5, wander_radius = 4.0, aggro_radius = 12.0, hostile = true  },
    Neck      = { speed = 1.0, wander_radius = 2.0, aggro_radius = 0,    hostile = false },
}

-- Returns the registry entry for the given prefab name, or nil if not managed.
function M.lookup(prefab_name)
    return prefab_name and M.entries[prefab_name] or nil
end

return M
