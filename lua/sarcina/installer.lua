-- sarcina/installer.lua
-- Core installer for Sarcina: queues every plugin's tasks and runs them.
-- Cloning is the `git_clone` task (see executors.lua), so it shows up in the task panel.

local M = {}

local ui = require('sarcina.ui')
local tasks = require('sarcina.tasks')

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

return M
