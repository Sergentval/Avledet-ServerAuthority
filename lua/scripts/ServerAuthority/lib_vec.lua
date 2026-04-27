--[[
    lib_vec — Vec3f helpers for Avledet-ServerAuthority Phase 1 stub AI.
    https://github.com/Sergentval/Avledet-ServerAuthority

    Phase 1 mob movement is horizontal-only — y is preserved from the input
    position. Ground-following via heightmap sampling is Phase 1.5. See
    PHASE-1-SPEC.md "Y-axis (vertical) handling — known gap".
--]]

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

-- Step from `from` toward `to` by at most `step_distance`. Result keeps from.y.
-- If already within step_distance (planar), snap to the target's XZ.
function M.advance_toward(from, to, step_distance)
    if from == nil or to == nil or step_distance == nil then return nil end
    local dx, dz = to.x - from.x, to.z - from.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist <= step_distance or dist == 0 then
        return Vec3f.new(to.x, from.y, to.z)
    end
    local k = step_distance / dist
    return Vec3f.new(from.x + dx * k, from.y, from.z + dz * k)
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
