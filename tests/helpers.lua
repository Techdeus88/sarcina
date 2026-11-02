-- tests/helpers.lua
-- Shared helpers for the headless test suite.

local M = {}

M.notes = {}

local registered = {}

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
    registered = {}
    local tasks = require('sarcina.tasks')
    tasks._jobs, tasks._plugins, tasks._order = {}, {}, {}
    tasks._running, tasks._started, tasks._callbacks = 0, false, {}
    tasks.max_concurrent = 4
    tasks.max_installs = 8
    require('sarcina.scheduler').clear_all()
    require('sarcina.load')._reset()
    require('sarcina.track')._reset()
    require('sarcina.stats')._reset()
    require('sarcina.window').forget()
    require('sarcina.installs')._reset()
    require('sarcina.paths').reset_dirs()
    vim.fn.delete(require('sarcina.paths').lock_file())
    require('sarcina.lock')._reset()
    pcall(vim.api.nvim_del_augroup_by_name, 'SarcinaUI')
    _G.lazy_log = nil
    local ui = require('sarcina.ui')
    ui.close()
    ui._listeners = {}
    ui._dismissed = false
    ui._seen_failed = 0
    ui._dirty, ui._want, ui._full = {}, false, false
    ui.show = 'auto'
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

--- Runs `git -C dir <args>` and returns what it printed, trimmed.
function M.git(dir, ...) return vim.trim(vim.fn.system({ 'git', '-C', dir, ... })) end

--- The commit `dir` is at.
function M.head(dir) return M.git(dir, 'rev-parse', 'HEAD') end

--- Adds a commit to the repo `dir`, which changes its tracked file.
function M.advance(dir)
    vim.fn.writefile({ tostring(vim.uv.hrtime()) }, dir .. '/tracked.txt')
    M.git(dir, 'add', '-A')
    M.git(dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'next')
end

--- A remote with a tracked file, which lets a fetch ask for a commit by its id, as GitHub does.
function M.upstream()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    M.git(dir, 'init', '-q')
    M.git(dir, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
    M.advance(dir)
    return dir
end

--- A git repo with one empty commit, for clones and builds. Returns its path.
function M.make_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
    local commit = { 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q' }
    vim.fn.system(vim.list_extend(commit, { '--allow-empty', '-m', 'init' }))
    return dir
end

--- Create a plugin dir holding lua/<module>/init.lua for each `modules` entry (module = body).
function M.plugin_dir(modules, root)
    local dir = root or vim.fn.tempname()
    for module, body in pairs(modules) do
        vim.fn.mkdir(dir .. '/lua/' .. module, 'p')
        vim.fn.writefile(vim.split(body, '\n'), dir .. '/lua/' .. module .. '/init.lua')
    end
    return dir
end

--- Register `plugins` ({ name, deps, tasks }) with the stats, one row each, as setup() does for the manifest.
--- `append` adds to the ones registered before. A plugin's `timing` defaults to 'later'.
function M.register(plugins, append)
    if not append then registered = {} end
    for _, plugin in ipairs(plugins) do
        table.insert(registered, { name = plugin.name, timing = plugin.timing or 'later', spec = plugin })
    end
    require('sarcina.stats').register(registered)
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
