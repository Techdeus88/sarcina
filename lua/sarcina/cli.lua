-- sarcina/cli.lua
-- Command dispatcher for :Sarcina

local M = {}

local installer = require('sarcina.installer')
local paths = require('sarcina.paths')
local resolver = require('sarcina.resolver')
local ui = require('sarcina.ui')

local SUBCOMMANDS =
    { 'add', 'remove', 'install', 'sync', 'clean', 'check', 'update', 'stats', 'panel', 'help' }

local subcommands = {}

function subcommands.add(args) ui.emit('info', 'Add command not yet implemented: ' .. args) end

function subcommands.remove(args) ui.emit('info', 'Remove command not yet implemented: ' .. args) end

-- The manifest as it is on disk now, resolved.
local function resolve_manifest() return resolver.resolve(require('sarcina.manifest').load()) end

-- Runs the plans of the plugins that have not loaded in this session (see installer.pending), and says which.
-- Returns false when there were none.
local function run_pending(resolved)
    local pending = installer.pending(resolved)
    if #pending == 0 then return false end
    local cloning, loading = {}, {}
    for _, entry in ipairs(pending) do
        table.insert(vim.uv.fs_stat(paths.install(entry.name)) and loading or cloning, entry.name)
    end
    local said = {}
    if #cloning > 0 then
        table.insert(said, string.format('Installing %d: %s', #cloning, table.concat(cloning, ', ')))
    end
    if #loading > 0 then
        table.insert(said, string.format('Loading %d: %s', #loading, table.concat(loading, ', ')))
    end
    ui.emit('info', table.concat(said, '. '))
    require('sarcina.stats').register(resolved)
    installer.install_all(pending)
    return true
end

-- Installs and loads the plugins that have not loaded in this session. One that has is left alone, so its config
-- never runs twice.
function subcommands.install(_)
    if not run_pending(resolve_manifest()) then ui.emit('info', 'Every plugin is installed and loaded') end
end

-- Lists the plugin directories that are not in your specs, or with `bang` deletes them. `command` is the
-- subcommand that deletes them. Returns false when there were none.
local function prune(resolved, bang, command)
    local stale = installer.stale(resolved)
    if #stale == 0 then return false end
    if not bang then
        ui.emit(
            'info',
            string.format(
                '%d not in your specs: %s. Run :Sarcina %s! to delete them.',
                #stale,
                table.concat(stale, ', '),
                command
            )
        )
        return true
    end
    local removed, failed = installer.remove(stale)
    if #removed > 0 then
        ui.emit('info', string.format('Removed %d: %s', #removed, table.concat(removed, ', ')))
    end
    for _, failure in ipairs(failed) do
        ui.emit('error', failure.name .. ': ' .. failure.why)
    end
    return true
end

-- An empty manifest makes every directory look removable, such as when a spec file failed to load.
local function refuse_empty(resolved, doing)
    if #resolved > 0 then return false end
    ui.emit(
        'error',
        'Not ' .. doing .. ': the manifest has no plugins, so every directory would look removable'
    )
    return true
end

-- Lists the plugin directories that are not in your specs; with a bang, deletes them.
function subcommands.clean(_, args)
    local resolved = resolve_manifest()
    if refuse_empty(resolved, 'cleaning') then return end
    if not prune(resolved, args.bang, 'clean') then ui.emit('info', 'Nothing to clean') end
end

-- `clean` and `install` in one: lists the directories no spec owns, or with a bang deletes them, and installs and
-- loads the plugins that have not loaded in this session.
function subcommands.sync(_, args)
    local resolved = resolve_manifest()
    if refuse_empty(resolved, 'syncing') then return end
    local pruned = prune(resolved, args.bang, 'sync')
    if not run_pending(resolved) and not pruned then ui.emit('info', 'Everything is in sync') end
end

function subcommands.check(_, args)
    require('sarcina.updater').check(resolve_manifest(), vim.list_slice(args.fargs, 2))
end

function subcommands.update(_, args)
    require('sarcina.updater').update(resolve_manifest(), vim.list_slice(args.fargs, 2))
end

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
