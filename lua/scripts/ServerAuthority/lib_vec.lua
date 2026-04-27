--[[
    lib_vec — Vec3f helpers for Avledet-ServerAuthority.
    https://github.com/Sergentval/Avledet-ServerAuthority

    Phase 3.0+: ground-following via HeightmapManager:get_height_at when
    available (requires the Avledet C++ Phase-3.0 binding). Falls back to
    flat-plane motion if HeightmapManager isn't bound (e.g., older Avledet
    builds), so the module remains backwards-compatible.
--]]

-- Detect Phase-3.0 binding once at load time. If HeightmapManager:get_height_at
-- exists, advance_toward will clamp result.y to ground height; otherwise it
-- preserves from.y as before. This keeps lib_vec usable on Avledet builds
-- without our C++ patch.
local function has_heightmap_binding()
    return HeightmapManager
        and type(HeightmapManager.get_height_at) == "function"
        or  pcall(function() return HeightmapManager:get_height_at(Vec3f.new(0,0,0)) end)
end
local HM_AVAILABLE = has_heightmap_binding()

local M = {}

-- Uniform random direction on the XZ unit circle. y = 0.
function M.random_horizontal_unit()
    local theta = math.random() * 2 * math.pi
    return Vec3f.new(math.cos(theta), 0, math.sin(theta))
end

-- Uniform sample in a disk of radius r around `center` (XZ plane).
-- sqrt(u) on the radius gives uniform area density, not radial bias.
function M.random_point_in_disk(center, r)
    if center == nil or r == nil then return nil end
    local theta = math.random() * 2 * math.pi
    local radius = math.sqrt(math.random()) * r
    return Vec3f.new(center.x + math.cos(theta) * radius, center.y, center.z + math.sin(theta) * radius)
end

-- Planar (XZ) distance, ignoring y. Avoids spurious distance from slope deltas.
function M.planar_distance(a, b)
    if a == nil or b == nil then return nil end
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

-- Step from `from` toward `to` by at most `step_distance`.
-- If HeightmapManager:get_height_at is bound (Avledet Phase-3.0 patch),
-- the returned position's y is clamped to ground height — so mobs follow
-- terrain instead of flying or clipping. Without the binding, falls back
-- to from.y (flat-plane motion).
-- If already within step_distance (planar), snap to the target's XZ.
function M.advance_toward(from, to, step_distance)
    if from == nil or to == nil or step_distance == nil then return nil end

    local dx, dz = to.x - from.x, to.z - from.z
    local dist = math.sqrt(dx * dx + dz * dz)

    local result_x, result_z, result_y
    if dist <= step_distance or dist == 0 then
        result_x, result_z = to.x, to.z
    else
        local k = step_distance / dist
        result_x, result_z = from.x + dx * k, from.z + dz * k
    end

    if HM_AVAILABLE then
        -- Probe the terrain at result.xz; HeightmapManager returns from.y if
        -- the heightmap zone isn't loaded (graceful fallback baked into
        -- the C++ side per PHASE-3-SPEC.md).
        local probe = Vec3f.new(result_x, from.y, result_z)
        result_y = HeightmapManager:get_height_at(probe)
    else
        result_y = from.y
    end

    return Vec3f.new(result_x, result_y, result_z)
end

-- Find the nearest ZDO from `candidates` to `origin`, within max_distance (planar).
-- Returns (zdo, distance) for the nearest in-range candidate, or (nil, nil) if none.
-- Distance is XZ-planar (ignores y), matching the rest of this module's convention.
--
-- candidates: table of ZDO objects with .pos returning Vec3f.
-- origin: Vec3f (typically a mob's current position).
-- max_distance: float (typically the mob's aggro_radius, or aggro_radius * 1.5 for
--               the drop-aggro check).
function M.find_nearest(origin, candidates, max_distance)
    if origin == nil or candidates == nil or max_distance == nil then return nil, nil end
    if max_distance <= 0 or #candidates == 0 then return nil, nil end
    local best_zdo, best_dist = nil, nil
    for _, zdo in ipairs(candidates) do
        local pos = zdo and zdo.pos
        if pos ~= nil then
            local d = M.planar_distance(origin, pos)
            if d ~= nil and d <= max_distance and (best_dist == nil or d < best_dist) then
                best_zdo, best_dist = zdo, d
            end
        end
    end
    if best_zdo == nil then return nil, nil end
    return best_zdo, best_dist
end

return M
