-- sarcina/cli.lua
-- Command dispatcher for :Sarcina

local M = {}

local installer = require('sarcina.installer')
local resolver = require('sarcina.resolver')
local ui = require('sarcina.ui')

local SUBCOMMANDS = { 'add', 'remove', 'install', 'sync', 'stats', 'panel', 'help' }

local subcommands = {}

function subcommands.add(args) ui.emit('info', 'Add command not yet implemented: ' .. args) end

function subcommands.remove(args) ui.emit('info', 'Remove command not yet implemented: ' .. args) end

function subcommands.install(_)
    ui.emit('info', 'Resolving manifest and installing...')
    local manifest = require('sarcina.manifest').load()
    local deps = resolver.resolve(manifest)
    installer.install_all(deps)
end

function subcommands.sync(_) ui.emit('info', 'Sync (install + prune) not yet implemented') end

function subcommands.stats(_)
    local stats = require('sarcina.stats').get()
    local startup = stats.startup_ms and string.format('startup %.0f ms', stats.startup_ms)
        or 'startup pending'
    ui.emit(
        'info',
        string.format(
            '%d plugins · %d loaded · %d not loaded · %d now · %d later · %d triggered · %s',
            stats.count,
            stats.loaded,
            stats.not_loaded,
            stats.now,
            stats.later,
            stats.triggered,
            startup
        )
    )
end

function subcommands.panel(_) ui.toggle() end

function subcommands.help(_) ui.emit('info', 'Subcommands: ' .. table.concat(SUBCOMMANDS, ', ')) end

function M.dispatch(args)
    local cmd, rest = args.fargs[1], table.concat(vim.list_slice(args.fargs, 2), ' ')
    if not cmd then
        ui.emit('error', 'No sub‑command provided. Use :Sarcina help')
        return
    end
    local fn = subcommands[cmd]
    if fn then
        fn(rest)
    else
        ui.emit('error', 'Unknown sub‑command: ' .. cmd)
    end
end

function M.complete(ArgLead)
    return vim.tbl_filter(function(c) return vim.startswith(c, ArgLead) end, SUBCOMMANDS)
end

return M
