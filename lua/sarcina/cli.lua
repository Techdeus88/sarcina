-- sarcina/cli.lua
-- Command dispatcher for :Sarcina

local M = {}

local installer = require('sarcina.installer')
local resolver = require('sarcina.resolver')
local ui = require('sarcina.ui')

local SUBCOMMANDS =
    { 'add', 'remove', 'install', 'sync', 'clean', 'check', 'update', 'stats', 'panel', 'help' }

local subcommands = {}

function subcommands.add(args) ui.emit('info', 'Add command not yet implemented: ' .. args) end

function subcommands.remove(args) ui.emit('info', 'Remove command not yet implemented: ' .. args) end

-- The manifest as it is on disk now, resolved.
local function resolve_manifest() return resolver.resolve(require('sarcina.manifest').load()) end

function subcommands.install(_)
    ui.emit('info', 'Resolving manifest and installing...')
    local deps = resolve_manifest()
    require('sarcina.stats').register(deps)
    installer.install_all(deps)
end

-- Lists the plugin directories that are not in your specs; with a bang, deletes them.
function subcommands.clean(_, args)
    local resolved = resolve_manifest()
    if #resolved == 0 then
        return ui.emit(
            'error',
            'Not cleaning: the manifest has no plugins, so every directory would look removable'
        )
    end
    local stale = installer.stale(resolved)
    if #stale == 0 then return ui.emit('info', 'Nothing to clean') end
    if not args.bang then
        return ui.emit(
            'info',
            string.format(
                '%d not in your specs: %s. Run :Sarcina clean! to delete them.',
                #stale,
                table.concat(stale, ', ')
            )
        )
    end
    local removed, failed = installer.remove(stale)
    if #removed > 0 then
        ui.emit('info', string.format('Removed %d: %s', #removed, table.concat(removed, ', ')))
    end
    for _, failure in ipairs(failed) do
        ui.emit('error', failure.name .. ': ' .. failure.why)
    end
end

function subcommands.check(_, args)
    require('sarcina.updater').check(resolve_manifest(), vim.list_slice(args.fargs, 2))
end

function subcommands.update(_, args)
    require('sarcina.updater').update(resolve_manifest(), vim.list_slice(args.fargs, 2))
end

function subcommands.sync(_) ui.emit('info', 'Sync (install + prune) not yet implemented') end

function subcommands.stats(_)
    ui.emit('info', require('sarcina.window').summary(require('sarcina.stats').get()))
end

function subcommands.panel(_) ui.toggle() end

function subcommands.help(_) ui.emit('info', 'Subcommands: ' .. table.concat(SUBCOMMANDS, ', ')) end

function M.dispatch(args)
    local cmd, rest = args.fargs[1], table.concat(vim.list_slice(args.fargs, 2), ' ')
    if not cmd then
        ui.emit('error', 'No sub‑command provided. Use :Sarcina help')
        return
    end
    -- `:Sarcina clean!` puts the bang on the argument, `:Sarcina! clean` on the command. Both mean the same.
    local bang = args.bang
    if vim.endswith(cmd, '!') then
        cmd, bang = cmd:sub(1, -2), true
    end
    local fn = subcommands[cmd]
    if fn then
        fn(rest, vim.tbl_extend('force', args, { bang = bang }))
    else
        ui.emit('error', 'Unknown sub‑command: ' .. cmd)
    end
end

-- Subcommand names, and after `check` or `update` the names of the plugins.
function M.complete(ArgLead, CmdLine)
    local candidates = SUBCOMMANDS
    if CmdLine and CmdLine:match('^%s*%S+%s+check%s') or CmdLine and CmdLine:match('^%s*%S+%s+update%s') then
        candidates = vim.tbl_map(function(entry) return entry.name end, require('sarcina.stats').specs())
    end
    return vim.tbl_filter(function(c) return vim.startswith(c, ArgLead) end, candidates)
end

return M
