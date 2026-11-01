-- sarcina/stats.lua
-- Numbers about the session: how many plugins there are, when each loads, how many loaded, and the time
-- to the UI. Pure data. It reads the tracker and the load gate, and never requires ui, emits or subscribes.

local load = require('sarcina.load')
local track = require('sarcina.track')

local M = {}

local origin = vim.uv.hrtime() -- when setup() began
local registered = {} -- plugin name -> 'now' | 'later' | 'trigger'

local CLASS = { now = 'now', later = 'later', trigger = 'triggered' }

--- Mark the start of setup(): `startup_ms` and every task time count from here.
function M.begin() origin = vim.uv.hrtime() end

--- Remember each plugin's timing, from a resolved manifest.
function M.register(resolved)
    registered = {}
    for _, entry in ipairs(resolved) do
        registered[entry.name] = entry.timing
    end
end

--- Every task of the session: start, end and duration in ms since setup() began, plus its metadata.
function M.tasks() return track.records(origin) end

-- A plugin is loaded when its rtp task is done and none of its tasks, at their latest run, failed.
local function loaded_plugins()
    local rtp_done, latest = {}, {}
    for _, job in ipairs(track.history()) do
        if job.type == 'rtp' and job.status == 'done' then rtp_done[job.plugin] = true end
        latest[job.plugin] = latest[job.plugin] or {}
        latest[job.plugin][job.id] = job
    end
    local loaded = {}
    for name in pairs(rtp_done) do
        loaded[name] = true
        for _, job in pairs(latest[name]) do
            if job.status == 'failed' then loaded[name] = nil end
        end
    end
    return loaded
end

--- The public numbers. `now` (eager), `later` (lazy) and `triggered` (loads when its event, ft, cmd or
--- keys fires) count plugins by configured timing, so they add up to `count`. `startup_ms` is absent
--- until the UI is up.
function M.get()
    local stats = { count = 0, loaded = 0, not_loaded = 0, now = 0, later = 0, triggered = 0 }
    local loaded = loaded_plugins()
    for name, timing in pairs(registered) do
        stats.count = stats.count + 1
        stats[CLASS[timing]] = stats[CLASS[timing]] + 1
        if loaded[name] then stats.loaded = stats.loaded + 1 end
    end
    stats.not_loaded = stats.count - stats.loaded
    local ready = load.ready_at()
    if ready then stats.startup_ms = math.max(ready - origin, 0) / 1e6 end
    return stats
end

--- Forget the origin and the registered plugins. For tests.
function M._reset()
    origin = vim.uv.hrtime()
    registered = {}
end

return M
