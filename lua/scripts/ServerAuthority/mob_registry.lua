-- mob_registry.lua — Phase 1 curated list of mob prefabs the stub AI manages.
-- ZDOs whose prefab is not in this table are left alone, even if server-owned.
-- See docs/PHASE-1-SPEC.md ("Mob registry"). Tick/idle defaults live in stub_ai.lua.

local M = {}

M.entries = {
    Boar      = { speed = 1.2, wander_radius = 4.0 },
    Deer      = { speed = 2.0, wander_radius = 6.0 },
    Greyling  = { speed = 1.0, wander_radius = 3.0 },
    Greydwarf = { speed = 1.5, wander_radius = 4.0 },
    Neck      = { speed = 1.0, wander_radius = 2.0 },
}

-- Returns the registry entry for the given prefab name, or nil if not managed.
function M.lookup(prefab_name)
    return prefab_name and M.entries[prefab_name] or nil
end

return M
