--[[
    stub_ai — Phase 1 idle-walk + Phase 2 aggro/chase AI for server-claimed mobs.
    https://github.com/Sergentval/Avledet-ServerAuthority

    Per-mob state machine: idle ↔ walking, plus chasing for hostile species.
    Hooks into Avledet's per-tick 'Update' event.

    Phase 1: idle/walking, throttled to 1Hz per mob, advances toward a random
    target inside the species wander radius.

    Phase 2: hostile mobs (registry.entry.hostile == true) scan for nearby
    Player ZDOs each tick; if one is within aggro_radius, lock onto it and
    transition to chasing. Chase ticks at 4Hz for smooth visible pursuit;
    aggro drops at 1.5× radius (hysteresis). No combat — that's Phase 4.

    See docs/PHASE-1-SPEC.md and docs/PHASE-2-SPEC.md.

    Out of scope:
      - pathfinding around obstacles (Phase 3)
      - combat / damage (Phase 4)
      - line-of-sight checks (Phase 3+)
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
    tick_interval_seconds       = 1.0,  -- idle/walking tick rate
    idle_probability            = 0.30,
    idle_duration_min           = 2.0,
    idle_duration_max           = 5.0,
    arrival_threshold           = 0.3,
    -- Phase 2 additions
    chase_step_interval_seconds = 0.25, -- chase ticks 4× faster for smooth pursuit
    aggro_drop_multiplier       = 1.5,  -- exit_threshold = aggro_radius * this
}

-- One player-ZDO snapshot per tick, shared across all mob aggro scans.
-- Key: now_seconds() float; reset on each tick boundary.
local _player_snapshot = nil
local _player_snapshot_at = -1

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

-- Get the list of all Player ZDOs, cached for the current tick. The cache
-- key is the float `now` value — when M.tick() advances `now`, the cache
-- is rebuilt on first request from the next tick. This keeps O(N×M) mob×
-- player aggro scans down to one ZDOManager:get_zdos call per tick.
local function snapshot_player_zdos_cached(now)
    if _player_snapshot ~= nil and _player_snapshot_at == now then
        return _player_snapshot
    end
    local list = {}
    local all = ZDOManager:get_zdos(function(zdo)
        return zdo.prefab and zdo.prefab.name == "Player"
    end)
    for _, z in ipairs(all) do list[#list + 1] = z end
    _player_snapshot = list
    _player_snapshot_at = now
    return list
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
        aggro_radius   = entry.aggro_radius or 0,
        hostile        = entry.hostile or false,

        state          = "idle",
        state_until    = now_seconds() + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max),
        target_pos     = nil,
        target_player_zdo = nil,  -- locked aggro target (Phase 2)
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

-- Move from idle/walking into chasing if a hostile mob spots a player.
-- Returns true if the transition fired (caller should bail out the rest of
-- the tick to avoid double-stepping).
local function maybe_aggro_scan(state, now)
    if not state.hostile or state.aggro_radius <= 0 then return false end
    if state.state == "chasing" then return false end

    local players = snapshot_player_zdos_cached(now)
    if #players == 0 then return false end

    local target, dist = lib_vec.find_nearest(state.zdo.pos, players, state.aggro_radius)
    if not target then return false end

    state.state = "chasing"
    state.target_player_zdo = target
    -- Per-state-transition log only — not per tick, to keep logs sane.
    print(string.format(
        "[StubAI] %s zdo=%s aggro on player at %.1fm",
        tostring(state.species), tostring(state.zdo.id.id), dist or -1
    ))
    return true
end

local function tick_one(state, now)
    -- Effective tick interval: chase ticks 4× faster for smooth pursuit.
    local interval = (state.state == "chasing")
        and DEFAULTS.chase_step_interval_seconds
        or  DEFAULTS.tick_interval_seconds
    if now - state.last_tick_at < interval then return end
    state.last_tick_at = now

    -- Bail if we lost ownership somehow (peer reclaimed).
    if not state.zdo.mine then
        M.release(state.zdo.id)
        return
    end

    -- Aggro scan can run from idle/walking. If it transitions us to chasing,
    -- the chasing branch below will pick up on this same tick.
    maybe_aggro_scan(state, now)

    if state.state == "chasing" then
        local target = state.target_player_zdo
        local cur = state.zdo.pos

        -- Defensive: target ZDO went away.
        if not target or not target.pos then
            print(string.format("[StubAI] %s zdo=%s drop aggro (target lost)",
                tostring(state.species), tostring(state.zdo.id.id)))
            state.target_player_zdo = nil
            state.state = "idle"
            state.state_until = now + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max)
            return
        end

        local target_pos = target.pos
        local dist = lib_vec.planar_distance(cur, target_pos)

        -- Drop aggro at hysteresis radius.
        local drop_threshold = state.aggro_radius * DEFAULTS.aggro_drop_multiplier
        if dist > drop_threshold then
            print(string.format("[StubAI] %s zdo=%s drop aggro (out of range, %.1fm > %.1fm)",
                tostring(state.species), tostring(state.zdo.id.id), dist, drop_threshold))
            state.target_player_zdo = nil
            state.state = "idle"
            state.state_until = now + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max)
            return
        end

        -- Don't walk into the player — stop just outside arrival_threshold.
        -- Phase 4 will wire combat in when we reach this distance.
        if dist <= DEFAULTS.arrival_threshold then return end

        -- Chase step. Speed × chase tick interval for proportional movement.
        local step = state.speed * DEFAULTS.chase_step_interval_seconds
        local next_pos = lib_vec.advance_toward(cur, target_pos, step)
        state.zdo.pos = next_pos
        return
    end

    if state.state == "idle" then
        if now < state.state_until then return end

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
            state.state = "idle"
            state.state_until = now + random_in_range(DEFAULTS.idle_duration_min, DEFAULTS.idle_duration_max)
            return
        end

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

    -- Invalidate the player snapshot at the start of each tick. The cache
    -- key is `now`, so the first mob to ask for it during this tick will
    -- rebuild it; subsequent mobs reuse it.
    _player_snapshot = nil
    _player_snapshot_at = -1

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
