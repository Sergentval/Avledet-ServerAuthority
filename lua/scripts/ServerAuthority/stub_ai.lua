--[[
    stub_ai — Phase 1 idle-walk AI for server-claimed mobs.
    https://github.com/Sergentval/Avledet-ServerAuthority

    Per-mob state machine: idle ↔ walking, throttled to 1Hz per mob.
    Hooks into Avledet's per-tick 'Update' event; advances each managed
    mob's position toward a randomly-chosen target inside its wander
    radius. When the target is reached or an idle timer expires, transitions
    to the other state.

    See docs/PHASE-1-SPEC.md for the design rationale.

    Out of scope (deferred to later phases):
      - aggro / target detection (Phase 2)
      - pathfinding around obstacles (Phase 3)
      - combat / damage (Phase 4)
      - vertical (y-axis) ground-following (Phase 1.5 — needs heightmap query)
      - persistence across server restart (Phase 5+)
--]]

local M = {}

-- Module-private dependency handles, populated by M.init().
-- Avledet's sandbox excludes `require`/`dofile`, so the entry script
-- (ServerAuthority.lua) is responsible for wiring the deps in via init().
local lib_vec = nil
local registry = nil

-- Default behaviour params; per-species overrides come from mob_registry.
local DEFAULTS = {
    tick_interval_seconds   = 1.0,
    idle_probability        = 0.30,
    idle_duration_min       = 2.0,
    idle_duration_max       = 5.0,
    arrival_threshold       = 0.3,
}

-- Map of zdo_id_string → state record. Keyed by string form because Lua
-- doesn't hash userdata-keyed tables across resets reliably.
local managed = {}
local managed_count = 0

-- Per-tick stats so we can sanity-check the rollout in the log.
local last_summary_at = 0
local SUMMARY_INTERVAL = 60.0

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function now_seconds()
    -- Avledet exposes Avledet.nanos as int nanos. Convert to fractional seconds.
    -- Fallback to os.time() if unavailable (test harness).
    if Avledet and Avledet.nanos then
        return Avledet.nanos / 1e9
    end
    return os.time()
end

local function random_in_range(lo, hi)
    return lo + math.random() * (hi - lo)
end

local function pick_new_walking_target(state)
    return lib_vec.random_point_in_disk(state.home_pos, state.wander_radius)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Start managing a server-owned mob ZDO. Idempotent — re-calling on the
-- same ZDO updates home_pos but preserves state.
function M.manage(zdo, prefab_name)
    if not zdo or not prefab_name then return false end

    local entry = registry.lookup(prefab_name)
    if not entry then return false end

    -- Composite key from the integer fields of ZDOID. Using `tostring(zdo.id)`
-- gave non-unique keys (sol2 userdata wrapper collision), causing every
-- mob to overwrite the same `managed` slot — only one mob ever ended
-- up registered. See the prefab-counts diagnostic from 2026-04-27.
local zid = zdo.id
local id_key = tostring(zid.user_id) .. ":" .. tostring(zid.id)
    if managed[id_key] then
        -- Already managed — refresh home in case mob was repositioned by the game.
        managed[id_key].home_pos = zdo.pos
        return true
    end

    managed[id_key] = {
        zdo            = zdo,
        species        = prefab_name,
        speed          = entry.speed,
        wander_radius  = entry.wander_radius,

        state          = "idle",
        state_until    = now_seconds() + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max),
        target_pos     = nil,
        last_tick_at   = 0,

        home_pos       = zdo.pos,
    }
    managed_count = managed_count + 1
    return true
end

-- Stop managing a mob (called when ownership flips back to a peer, or
-- when the ZDO is destroyed). Safe to call on unknown IDs.
function M.release(zdo_id)
    if not zdo_id then return end
    -- Same composite-key trick as M.manage. zdo_id is a ZDOID userdata.
    local id_key = tostring(zdo_id.user_id) .. ":" .. tostring(zdo_id.id)
    if managed[id_key] then
        managed[id_key] = nil
        managed_count = managed_count - 1
    end
end

-- Returns the current count of managed mobs. Used by ServerAuthority.lua
-- for log output.
function M.count()
    return managed_count
end

-- Returns a per-species count summary. Useful for periodic diagnostics.
function M.species_summary()
    local out = {}
    for _, state in pairs(managed) do
        out[state.species] = (out[state.species] or 0) + 1
    end
    return out
end

----------------------------------------------------------------------
-- Tick
----------------------------------------------------------------------

local function tick_one(state, now)
    -- Throttle to per-mob tick_interval. Cheap early-return.
    if now - state.last_tick_at < DEFAULTS.tick_interval_seconds then return end
    state.last_tick_at = now

    -- Bail if we lost ownership somehow (peer reclaimed).
    if not state.zdo.mine then
        M.release(state.zdo.id)
        return
    end

    if state.state == "idle" then
        if now < state.state_until then return end

        -- State expired — pick next: either re-idle, or start walking.
        if math.random() < DEFAULTS.idle_probability then
            state.state_until = now + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max)
        else
            state.state = "walking"
            state.target_pos = pick_new_walking_target(state)
        end
        return
    end

    if state.state == "walking" then
        local cur = state.zdo.pos
        local d = lib_vec.planar_distance(cur, state.target_pos)

        if d < DEFAULTS.arrival_threshold then
            -- Arrived — go idle.
            state.state = "idle"
            state.state_until = now + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max)
            return
        end

        -- Step toward the target. Step distance scales with tick interval.
        local step = state.speed * DEFAULTS.tick_interval_seconds
        local next_pos = lib_vec.advance_toward(cur, state.target_pos, step)
        state.zdo.pos = next_pos
        return
    end
end

-- Called every game tick by Avledet's Update event. Inexpensive when
-- managed_count is small; per-mob tick_interval gates real work.
function M.tick()
    if managed_count == 0 then return end

    local now = now_seconds()

    for _, state in pairs(managed) do
        local ok, err = pcall(tick_one, state, now)
        if not ok then
            print("[StubAI] tick error for " .. tostring(state.species) .. ": " .. tostring(err))
        end
    end

    -- Periodic species summary (every 60s) for log-driven sanity checks.
    if now - last_summary_at >= SUMMARY_INTERVAL then
        last_summary_at = now
        local summary = M.species_summary()
        local parts = {}
        for sp, n in pairs(summary) do parts[#parts + 1] = sp .. "=" .. n end
        if #parts > 0 then
            print("[StubAI] managing " .. managed_count .. " mobs (" .. table.concat(parts, ", ") .. ")")
        end
    end
end

----------------------------------------------------------------------
-- Loader contract
----------------------------------------------------------------------
-- Avledet's sandbox excludes `require`/`dofile`/`loadfile`. The deploy
-- pipeline concatenates lib_vec.lua + mob_registry.lua + stub_ai.lua +
-- ServerAuthority.lua into a single ServerAuthority.lua at deploy time
-- (see tools/bundle.sh). The entry script then wires deps via init():
--
--   stub_ai.init(lib_vec, mob_registry)
--   stub_ai.subscribe()
--
-- This pattern keeps each source file self-contained and importable in
-- the build script while staying compatible with Avledet's one-entry-
-- script-per-directory mod loader.
----------------------------------------------------------------------

function M.init(lib_vec_module, mob_registry_module)
    lib_vec = lib_vec_module
    registry = mob_registry_module
end

function M.subscribe()
    if not lib_vec or not registry then
        error("[StubAI] init(lib_vec, mob_registry) must be called before subscribe()")
    end
    Avledet:subscribe('Update', function()
        M.tick()
    end)
    print("[StubAI] subscribed to Update event; managing " .. managed_count .. " mobs")
end

return M
