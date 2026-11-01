-- sarcina/tasks.lua
-- Task store and async runner for Sarcina.
-- Owns all task state. The UI reads `snapshot()` and keeps no copy of its own.

local M = {}

local ui = require('sarcina.ui')
local executors = require('sarcina.executors')
local track = require('sarcina.track')

M.max_concurrent = 4
M.max_installs = 8

M._jobs = {}
M._plugins = {}
M._order = {}
M._running = 0
M._started = false
M._quiet = false
M._fresh = false
M._counted = 0
M._callbacks = {}

local run_job, pump

local function emit(job) ui.emit('task', job) end

local function reset()
    M._jobs, M._plugins, M._order, M._running = {}, {}, {}, 0
    M._counted = 0
    M._fresh = true
end

--- Start a new job list, unless a run is still going. Enqueue and run_inline with `append` after it.
function M.begin()
    if not M.has_active() then reset() end
end

function M.has_active()
    for _, job in ipairs(M._jobs) do
        if job.status == 'pending' or job.status == 'running' then return true end
    end
    return false
end

function M.snapshot()
    local counts = { pending = 0, running = 0, done = 0, failed = 0, skipped = 0 }
    for _, job in ipairs(M._jobs) do
        counts[job.status] = counts[job.status] + 1
    end
    return { jobs = M._jobs, counts = counts, total = #M._jobs }
end

function M.plugin_failed(name)
    local plugin = M._plugins[name]
    return plugin ~= nil and plugin.failed == true
end

-- Evaluate a `when` Lua expression safely; returns true if missing.
local function condition_ok(task)
    if not task.when then return true end
    local fn = loadstring('return ' .. task.when)
    if not fn then return false end
    local ok, res = pcall(fn)
    return ok and res and true or false
end

local function plugin_record(name, plugin_spec)
    local plugin = M._plugins[name]
    if not plugin then
        plugin = { name = name, deps = {}, jobs = {}, next = 1 }
        M._plugins[name] = plugin
        table.insert(M._order, name)
    end
    local deps = plugin_spec.deps or plugin_spec.dependencies
    if type(deps) == 'table' and #deps > 0 then plugin.deps = deps end
    return plugin
end

local function new_job(plugin_name, task)
    local job = {
        plugin = plugin_name,
        id = task.id,
        type = task.type,
        spec = task,
        status = 'pending',
        attempts = 0,
    }
    track.created(job)
    return job
end

--- Enqueue all tasks for a given plugin spec (if conditions pass).
--- A new run replaces the job list. `opts.append` adds to it instead, so earlier results stay visible.
--- Tasks added to a plugin that already failed are skipped.
function M.enqueue(plugin_name, plugin_spec, opts)
    if not (opts and opts.append) and not M.has_active() then reset() end
    local plugin = plugin_record(plugin_name, plugin_spec)
    for _, task in ipairs(plugin_spec.tasks or {}) do
        if condition_ok(task) then
            local job = new_job(plugin_name, task)
            if plugin.failed then
                job.status = 'skipped'
                job.note = 'an earlier task failed'
            end
            table.insert(plugin.jobs, job)
            table.insert(M._jobs, job)
            if plugin.failed then plugin.next = #plugin.jobs + 1 end
            emit(job)
        end
    end
end

-- Runs one job to the end before returning. An executor that answers later is waited for.
local function run_now(job)
    job.attempts = 1
    job.status = 'running'
    track.started(job)
    emit(job)
    local result
    local function done(ok, msg) result = result or { ok = ok, msg = msg } end
    local exec = executors[job.type]
    if not exec then
        done(false, 'unknown task type ' .. tostring(job.type))
    else
        local ok, err = pcall(exec, job, done, function() end)
        if not ok then done(false, err) end
        if not result then vim.wait(60000, function() return result ~= nil end, 1) end
        if not result then done(false, 'timed out') end
    end
    track.finished(job)
    if result.ok then
        job.status = 'done'
        job.note = type(result.msg) == 'string' and result.msg or nil
    else
        job.status = 'failed'
        job.error = tostring(result.msg or 'unknown error')
    end
    emit(job)
    return result.ok
end

--- Run a plugin's tasks right now, in order, without returning to the event loop. The jobs are recorded
--- like any others but never queued, so the runner does not run them again. A failure skips the rest
--- and marks the plugin failed. Returns true when every task succeeded.
function M.run_inline(plugin_name, plugin_spec)
    local plugin = plugin_record(plugin_name, plugin_spec)
    local jobs = {}
    for _, task in ipairs(plugin_spec.tasks or {}) do
        if condition_ok(task) then
            local job = new_job(plugin_name, task)
            table.insert(jobs, job)
            table.insert(M._jobs, job)
            emit(job)
        end
    end
    for i, job in ipairs(jobs) do
        if not run_now(job) then
            for j = i + 1, #jobs do
                jobs[j].status = 'skipped'
                jobs[j].note = job.id .. ' failed'
                emit(jobs[j])
            end
            plugin.failed = true
            return false
        end
    end
    return true
end

local function skip_rest(plugin, reason)
    for i = plugin.next, #plugin.jobs do
        local job = plugin.jobs[i]
        job.status = 'skipped'
        job.note = reason
        emit(job)
    end
    plugin.next = #plugin.jobs + 1
    plugin.failed = true
end

local function dependency_state(plugin)
    for _, dep_name in ipairs(plugin.deps) do
        local dep = M._plugins[dep_name]
        if dep then
            if dep.failed then return 'failed', dep_name end
            if dep.running or dep.next <= #dep.jobs then return 'waiting' end
        end
    end
    return 'ready'
end

local function is_install(job) return job.spec.phase == 'install' end

-- True while any plugin is about to run or is running an install job. Nothing else starts then.
local function installs_in_flight()
    for _, name in ipairs(M._order) do
        local plugin = M._plugins[name]
        if plugin.running then
            if is_install(plugin.jobs[plugin.next - 1]) then return true end
        elseif plugin.next <= #plugin.jobs and is_install(plugin.jobs[plugin.next]) then
            return true
        end
    end
    return false
end

-- Counts the jobs added since the last summary, so an appended run reports only itself.
local function summarize()
    local summary = { total = 0, done = 0, failed = 0, skipped = 0 }
    for i = M._counted + 1, #M._jobs do
        local status = M._jobs[i].status
        summary.total = summary.total + 1
        summary[status] = summary[status] + 1
    end
    M._counted = #M._jobs
    return summary
end

local function settle()
    if M._running > 0 then return end
    for _, name in ipairs(M._order) do
        local plugin = M._plugins[name]
        if plugin.next <= #plugin.jobs then
            skip_rest(plugin, 'dependencies never completed')
            return pump()
        end
    end
    M._started = false
    local summary = summarize()
    if M._quiet then summary.quiet = true end
    ui.emit('done', summary)
    local callbacks = M._callbacks
    M._callbacks = {}
    for _, cb in ipairs(callbacks) do
        local ok, err = pcall(cb, summary)
        if not ok then ui.emit('error', 'Task completion callback failed: ' .. tostring(err)) end
    end
end

local function finish(plugin, job, ok, msg)
    track.finished(job)
    if ok then
        job.status = 'done'
        job.note = type(msg) == 'string' and msg or nil
        job.error = nil
        emit(job)
    else
        job.error = tostring(msg or 'unknown error')
        if job.attempts <= (job.spec.retries or 0) then return run_job(plugin, job) end
        job.status = 'failed'
        emit(job)
        skip_rest(plugin, job.id .. ' failed')
    end
    plugin.running = false
    M._running = M._running - 1
    pump()
end

function run_job(plugin, job)
    job.attempts = job.attempts + 1
    job.status = 'running'
    job.error = nil
    job.output = nil
    track.started(job)
    emit(job)

    local settled = false
    local function done(ok, msg)
        if settled then return end
        settled = true
        vim.schedule(function() finish(plugin, job, ok, msg) end)
    end
    local function report(line)
        vim.schedule(function()
            if job.status == 'running' then
                job.output = line
                emit(job)
            end
        end)
    end

    local exec = executors[job.type]
    if not exec then return done(false, 'unknown task type ' .. tostring(job.type)) end
    local ok, err = pcall(exec, job, done, report)
    if not ok then done(false, err) end
end

local function start(plugin)
    local job = plugin.jobs[plugin.next]
    plugin.next = plugin.next + 1
    plugin.running = true
    M._running = M._running + 1
    run_job(plugin, job)
end

-- Installs go first: every install job starts at once, whatever its plugin depends on, and no other
-- job starts until all of them have finished.
function pump()
    if not M._started then return end
    local skipped
    repeat
        skipped = false
        local installing = installs_in_flight()
        local limit = installing and M.max_installs or M.max_concurrent
        for _, name in ipairs(M._order) do
            local plugin = M._plugins[name]
            if not plugin.running and plugin.next <= #plugin.jobs then
                if is_install(plugin.jobs[plugin.next]) then
                    if M._running < limit then start(plugin) end
                elseif not installing then
                    local state, dep = dependency_state(plugin)
                    if state == 'failed' then
                        skip_rest(plugin, 'dependency ' .. dep .. ' failed')
                        skipped = true
                    elseif state == 'ready' and M._running < limit then
                        start(plugin)
                    end
                end
            end
        end
    until not skipped
    settle()
end

--- Start running everything enqueued. Returns immediately; `on_done(summary)` fires when the queue drains.
--- `opts.quiet` hides the end-of-run toast when nothing failed. `opts.append` keeps the earlier job list.
function M.run_all(on_done, opts)
    local quiet = opts ~= nil and opts.quiet == true
    local append = opts ~= nil and opts.append == true
    if on_done then table.insert(M._callbacks, on_done) end
    if M._started then
        M._quiet = M._quiet and quiet
        return
    end
    if not append and not M.has_active() then reset() end
    local fresh = M._fresh
    M._fresh = false
    M._started = true
    M._quiet = quiet
    ui.emit('start', { total = #M._jobs, fresh = fresh })
    vim.schedule(pump)
end

--- Block (while still pumping the event loop) until the queue drains. Returns false on timeout.
function M.wait(timeout)
    -- A run that is queued but waits for the UI starts now, since this call blocks until it is done.
    if not M._started and M.has_active() then M.run_all(nil, { append = true, quiet = true }) end
    return vim.wait(timeout or 60000, function() return not M._started and not M.has_active() end, 5)
end

return M
