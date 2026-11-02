-- sarcina/installer.lua
-- Core installer for Sarcina: queues every plugin's tasks and runs them.
-- Cloning is the `git_clone` task (see executors.lua), so it shows up in the task panel.

local M = {}

local installs = require('sarcina.installs')
local lock = require('sarcina.lock')
local paths = require('sarcina.paths')
local tasks = require('sarcina.tasks')
local track = require('sarcina.track')
local ui = require('sarcina.ui')

--- Queue every task for a single plugin.
--- `plugin_name` is a string identifier (e.g. "telescope.nvim").
function M.install_one(plugin_name, spec) tasks.enqueue(plugin_name, spec) end

--- Queue and run every plugin described by a resolved manifest.
--- `resolved` is expected to be a list of tables: { name = <string>, spec = <table> }.
--- Returns immediately; `on_done(summary)` fires once the queue drains. `opts.quiet` skips the
--- end-of-run toast unless something failed.
function M.install_all(resolved, on_done, opts)
    ui.emit('debug', string.format('Starting bulk install of %d plugins', #resolved))
    for _, entry in ipairs(resolved) do
        M.install_one(entry.name, entry.spec)
    end
    tasks.run_all(on_done, opts)
end

-- Whether a plugin's plan is queued or running, or got far enough this session that running it again would call
-- its config twice: it is on the runtimepath, or its trigger is armed.
local function under_way(name)
    for _, job in ipairs(track.jobs_of(name)) do
        if job.status == 'pending' or job.status == 'running' then return true end
        if (job.id == 'rtp' or job.id == 'load_trigger') and job.status == 'done' then return true end
    end
    return false
end

--- The plugins of `resolved` whose plan has to run: the ones that have not loaded, are not waiting for a trigger
--- and are not queued in this session, such as a plugin that is not on disk, one new in your specs, or one that a
--- failure stopped before it loaded.
function M.pending(resolved)
    return vim.tbl_filter(function(entry) return not under_way(entry.name) end, resolved)
end

--- The directories in the plugins directory, by name, sorted. Files are not plugins, and a name read from the
--- directory cannot point outside it.
function M.installed()
    local found = {}
    local handle = vim.uv.fs_scandir(paths.plugins_dir())
    while handle do
        local name, kind = vim.uv.fs_scandir_next(handle)
        if not name then break end
        local hidden = name:sub(1, 1) == '.' -- sarcina's own, such as .staging
        if (kind == 'directory' or kind == 'link') and not hidden then table.insert(found, name) end
    end
    table.sort(found)
    return found
end

--- The installed directories that no plugin of `resolved` owns, by name.
function M.stale(resolved)
    local wanted = {}
    for _, entry in ipairs(resolved) do
        wanted[entry.name] = true
    end
    return vim.tbl_filter(function(name) return not wanted[name] end, M.installed())
end

--- Delete the plugin directories `names`: off the runtimepath, then from disk, then out of the install times
--- and the lock file. Returns the names removed and `{ name, why }` for each that could not be.
function M.remove(names)
    local removed, failed = {}, {}
    for _, name in ipairs(names) do
        local dir = paths.install(name)
        vim.opt.rtp:remove(dir)
        vim.opt.rtp:remove(dir .. '/after')
        if vim.fn.delete(dir, 'rf') == 0 then
            table.insert(removed, name)
        else
            table.insert(failed, { name = name, why = 'could not delete ' .. dir })
        end
    end
    installs.forget(removed)
    lock.forget(removed)
    return removed, failed
end

return M
