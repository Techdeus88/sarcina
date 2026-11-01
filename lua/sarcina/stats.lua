-- sarcina/stats.lua
-- Numbers about the session: how many plugins there are, when each loads, how many loaded, the time to
-- the UI, and a row per plugin that says where it is in its tasks. Pure data. It reads the tracker and the
-- load gate, and never requires ui, emits or subscribes.

local load = require('sarcina.load')
local track = require('sarcina.track')

local M = {}

local origin = vim.uv.hrtime() -- when setup() began
local registered = {} -- plugin name -> { timing = 'now' | 'later' | 'trigger', plan = task ids }
local order = {} -- plugin names in load order

local CLASS = { now = 'now', later = 'later', trigger = 'triggered' }

--- Mark the start of setup(): `startup_ms` and every task time count from here.
function M.begin() origin = vim.uv.hrtime() end

-- The ids of a plugin's whole task plan in order, with the tasks a trigger holds back after it.
local function plan_of(spec)
    local plan = {}
    for _, task in ipairs(spec and spec.tasks or {}) do
        table.insert(plan, task.id)
        for _, deferred in ipairs(task.deferred or {}) do
            table.insert(plan, deferred.id)
        end
    end
    return plan
end

--- Remember each plugin's timing and task plan, from a resolved manifest, in load order.
function M.register(resolved)
    registered, order = {}, {}
    for _, entry in ipairs(resolved) do
        table.insert(order, entry.name)
        registered[entry.name] = { timing = entry.timing, plan = plan_of(entry.spec) }
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
    for name, entry in pairs(registered) do
        stats.count = stats.count + 1
        stats[CLASS[entry.timing]] = stats[CLASS[entry.timing]] + 1
        if loaded[name] then stats.loaded = stats.loaded + 1 end
    end
    stats.not_loaded = stats.count - stats.loaded
    local ready = load.ready_at()
    if ready then stats.startup_ms = math.max(ready - origin, 0) / 1e6 end
    return stats
end

-- The position in `plan` the plugin is at. A task that was never created counts as done when a later
-- one was, as an install already on disk does. Running beats failed beats the last finished task.
local function position(plan, latest)
    local created = 0
    for i, id in ipairs(plan) do
        if latest[id] then created = i end
    end
    local running, failed, finished = nil, nil, 0
    for i, id in ipairs(plan) do
        local status = latest[id] and latest[id].status or (i < created and 'done' or 'pending')
        if status == 'running' then
            running = running or i
        elseif status == 'failed' then
            failed = failed or i
        elseif status == 'done' then
            finished = i
        end
    end
    return running or failed or finished
end

-- The first line of an error without the file and line a Lua error starts with.
local function first_line(text)
    local line = tostring(text):match('[^\n]+') or 'unknown'
    return (line:gsub('^%S+%.lua:%d+: ', ''))
end

local WORKING = { install = 'installing', build = 'building' }

-- install and build count as work only once they really started, since a clone of what is on disk and a
-- build whose commit did not change finish at once.
local function is_work(job) return WORKING[job.id] == nil or job.working == true end

-- The state of a plugin and the line that says more, from its latest job of each task id.
local function state_of(latest, jobs)
    local running, skipped, pending
    for _, job in ipairs(jobs) do
        if latest[job.id] == job then
            if job.status == 'failed' then return 'failed', first_line(job.error) end
            if job.status == 'running' and is_work(job) then running = running or job end
            if job.status == 'skipped' then skipped = skipped or job end
            if job.status == 'pending' then pending = true end
        end
    end
    if running then
        local detail = running.output
        if running.attempts > 1 then
            detail = 'try ' .. running.attempts .. (detail and ' · ' .. detail or '')
        end
        return WORKING[running.id] or 'loading', detail
    end
    if skipped then return 'blocked', skipped.note end
    local rtp, trigger = latest.rtp, latest.load_trigger
    if rtp and rtp.status == 'done' then return pending and 'loading' or 'loaded' end
    if trigger and trigger.status == 'done' then
        return rtp and 'loading' or 'waiting', not rtp and trigger.note or nil
    end
    return 'pending'
end

local function row_of(name)
    local entry = registered[name]
    local jobs = track.jobs_of(name)
    local row = { name = name, timing = entry.timing, state = 'pending', task = 0, tasks = #entry.plan }
    if #jobs == 0 then return row end
    local latest, duration = {}, 0
    for _, job in ipairs(jobs) do
        latest[job.id] = job
    end
    for _, job in pairs(latest) do
        duration = duration + (job.duration or 0)
    end
    row.state, row.detail = state_of(latest, jobs)
    row.task = row.state == 'loaded' and row.tasks or position(entry.plan, latest)
    row.duration = duration > 0 and duration or nil
    return row
end

--- One row for a registered plugin, or nil: `name`, `timing`, `state`, `task` of `tasks` (the plugin is at
--- task 3 of 8), `detail` and `duration` in ms. `state` is pending, installing, building, loading, waiting
--- (for its trigger), loaded, blocked or failed. An install of what is on disk and a build whose commit
--- did not change never show as work.
function M.plugin(name)
    if registered[name] then return row_of(name) end
end

--- `plugin` for every registered plugin, in load order.
function M.plugins() return vim.tbl_map(row_of, order) end

--- Forget the origin and the registered plugins. For tests.
function M._reset()
    origin = vim.uv.hrtime()
    registered, order = {}, {}
end

return M
