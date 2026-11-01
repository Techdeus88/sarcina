-- tests/helpers.lua
-- Shared helpers for the headless test suite.

local M = {}

M.notes = {}

--- Point every XDG dir at a throwaway root and capture vim.notify.
function M.setup_env()
    local root = vim.fn.tempname()
    for _, name in ipairs({ 'DATA', 'CACHE', 'STATE', 'CONFIG' }) do
        vim.env['XDG_' .. name .. '_HOME'] = root .. '/' .. name:lower()
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level) table.insert(M.notes, { msg = msg, level = level }) end
end

--- Clear task, UI and notification state between tests.
function M.reset()
    M.notes = {}
    local tasks = require('sarcina.tasks')
    tasks._jobs, tasks._plugins, tasks._order = {}, {}, {}
    tasks._running, tasks._started, tasks._callbacks = 0, false, {}
    tasks.max_concurrent = 4
    tasks.max_installs = 8
    require('sarcina.scheduler').clear_all()
    require('sarcina.load')._reset()
    require('sarcina.track')._reset()
    require('sarcina.stats')._reset()
    _G.lazy_log = nil
    local ui = require('sarcina.ui')
    ui.close()
    ui._listeners = {}
    ui._dismissed = false
    ui._delay_passed = true
    ui._seen_failed = 0
    ui.show_delay = 250
    ui.close_delay = 60000
end

function M.eq(actual, expected, msg)
    if not vim.deep_equal(actual, expected) then
        local prefix = msg and (msg .. ': ') or ''
        error(string.format('%sexpected %s, got %s', prefix, vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

function M.ok(cond, msg)
    if not cond then error(msg or 'assertion failed', 2) end
end

function M.notified(text)
    for _, note in ipairs(M.notes) do
        if note.msg:find(text, 1, true) then return true end
    end
    return false
end

function M.names(entries)
    return vim.tbl_map(function(entry) return entry.name end, entries)
end

function M.ids(tasks)
    return vim.tbl_map(function(task) return task.id end, tasks)
end

--- A `lua` task running `fn`; `extra` fields (retries, when, ...) are merged in.
function M.lua(id, fn, extra) return vim.tbl_extend('force', { id = id, type = 'lua', fn = fn }, extra or {}) end

function M.noop() end

--- Create a plugin dir holding lua/<module>/init.lua for each `modules` entry (module = body).
function M.plugin_dir(modules, root)
    local dir = root or vim.fn.tempname()
    for module, body in pairs(modules) do
        vim.fn.mkdir(dir .. '/lua/' .. module, 'p')
        vim.fn.writefile(vim.split(body, '\n'), dir .. '/lua/' .. module .. '/init.lua')
    end
    return dir
end

--- Enqueue `plugins` ({ name, deps, tasks }), run to completion, and return the summary.
function M.run(plugins, opts)
    local tasks = require('sarcina.tasks')
    for _, plugin in ipairs(plugins) do
        tasks.enqueue(plugin.name, plugin)
    end
    local summary
    tasks.run_all(function(s) summary = s end, opts)
    assert(tasks.wait(5000), 'tasks did not finish')
    return summary
end

function M.job(plugin, id)
    for _, job in ipairs(require('sarcina.tasks').snapshot().jobs) do
        if job.plugin == plugin and job.id == id then return job end
    end
end

return M
