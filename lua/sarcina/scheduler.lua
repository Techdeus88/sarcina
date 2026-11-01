-- sarcina/scheduler.lua
-- Lazy-load triggers. The `trigger` task hands its plugin to `register`, which installs stubs for
-- the plugin's event/ft/cmd/keys. The first stub to fire removes them all, runs the plugin's
-- deferred tasks (rtp, config, after) through the task runner, then replays what triggered it.

local M = {}

local keys = require('sarcina.keys')
local load = require('sarcina.load')
local replay = require('sarcina.replay')
local tasks = require('sarcina.tasks')

-- name -> { name, triggers, deferred, deps, state = waiting|loading|loaded|failed, ... }
M._plugins = {}

--- One-line summary of a triggers table, e.g. "BufRead, ft:lua, :Telescope, <leader>ff".
function M.describe(triggers)
    local parts = {}
    for _, event in ipairs(triggers.event or {}) do
        table.insert(parts, event)
    end
    for _, ft in ipairs(triggers.ft or {}) do
        table.insert(parts, 'ft:' .. ft)
    end
    for _, cmd in ipairs(triggers.cmd or {}) do
        table.insert(parts, ':' .. cmd)
    end
    for _, map in ipairs(triggers.keys or {}) do
        table.insert(parts, keys.parse(map).lhs)
    end
    return table.concat(parts, ', ')
end

-- Stubs ------------------------------------------------------------------------------------

-- 'BufRead *.lua' is the event and its pattern; a bare event matches everything.
local function parse_event(spec)
    local event, pattern = spec:match('^(%S+)%s+(.+)$')
    return event or spec, pattern or '*'
end

local function arm(plugin)
    local name, triggers = plugin.name, plugin.triggers
    plugin.augroup = vim.api.nvim_create_augroup('SarcinaScheduler_' .. name, { clear = true })

    for _, spec in ipairs(triggers.event or {}) do
        local event, pattern = parse_event(spec)
        vim.api.nvim_create_autocmd(event, {
            group = plugin.augroup,
            pattern = pattern,
            callback = function(args) M.load(name, replay.event(event, args)) end,
        })
    end

    if triggers.ft then
        vim.api.nvim_create_autocmd('FileType', {
            group = plugin.augroup,
            pattern = triggers.ft,
            callback = function(args) M.load(name, replay.event('FileType', args)) end,
        })
    end

    for _, cmd in ipairs(triggers.cmd or {}) do
        vim.api.nvim_create_user_command(
            cmd,
            function(opts) M.load(name, replay.command(cmd, opts)) end,
            { nargs = '*', bang = true, range = true }
        )
        table.insert(plugin.commands, cmd)
    end

    for _, map in ipairs(triggers.keys or {}) do
        local key = keys.parse(map)
        if key.lhs then
            -- The stub only loads the plugin; the options that shape the real mapping wait for its rhs.
            local opts = { silent = key.opts.silent, desc = key.opts.desc, nowait = key.opts.nowait }
            vim.keymap.set(key.mode, key.lhs, function() M.load(name, replay.keys(key.lhs)) end, opts)
            table.insert(plugin.keymaps, { mode = key.mode, lhs = key.lhs })
        end
    end
end

local function disarm(plugin)
    pcall(vim.api.nvim_del_augroup_by_id, plugin.augroup)
    for _, cmd in ipairs(plugin.commands) do
        pcall(vim.api.nvim_del_user_command, cmd)
    end
    for _, key in ipairs(plugin.keymaps) do
        pcall(vim.keymap.del, key.mode, key.lhs)
    end
    plugin.commands, plugin.keymaps = {}, {}
end

-- Catch-up ---------------------------------------------------------------------------------

-- Events that a buffer which is already open has been through.
local BUFFER_EVENTS = {
    BufReadPre = true,
    BufReadPost = true,
    BufRead = true,
    BufEnter = true,
    BufWinEnter = true,
    BufAdd = true,
    BufNew = true,
}

local function loaded_buffers() return vim.tbl_filter(vim.api.nvim_buf_is_loaded, vim.api.nvim_list_bufs()) end

local function is_file_buffer(buf) return vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= '' end

-- A pattern like '*.lua' or 'init.lua' may name the whole path or only the file.
local function matches(pattern, name)
    return replay.matches(pattern, name) or replay.matches(pattern, vim.fs.basename(name))
end

-- Events that cannot fire again: VimEnter once Neovim has started, UIEnter once the UI is up.
local function has_fired(event)
    return event == 'VimEnter' and vim.v.vim_did_enter == 1 or event == 'UIEnter' and load.ready_at() ~= nil
end

-- The event triggers of a plugin as { event, pattern } pairs. An `ft` trigger is a FileType event.
local function event_triggers(triggers)
    local list = {}
    for _, spec in ipairs(triggers.event or {}) do
        local event, pattern = parse_event(spec)
        table.insert(list, { event = event, pattern = pattern })
    end
    for _, ft in ipairs(triggers.ft or {}) do
        table.insert(list, { event = 'FileType', pattern = ft })
    end
    return list
end

-- A plugin whose stubs were armed late, because it was only cloned once the UI was up, missed the events
-- that already happened. Loads it now if one left a trace: a buffer that is already open with a matching
-- filetype or file name, or VimEnter or UIEnter. The load replays the plugin's own handlers for that buffer.
local function catch_up(plugin)
    if M._plugins[plugin.name] ~= plugin or plugin.state ~= 'waiting' then return end
    local buffers = loaded_buffers()
    local function wake(event, buf, text)
        local file = vim.api.nvim_buf_get_name(buf)
        M.load(plugin.name, replay.event(event, { event = event, buf = buf, file = file, match = text }))
    end
    for _, trigger in ipairs(event_triggers(plugin.triggers)) do
        local event = trigger.event
        if has_fired(event) then return wake(event, vim.api.nvim_get_current_buf(), '') end
        for _, buf in ipairs(buffers) do
            if event == 'FileType' then
                local filetype = vim.bo[buf].filetype
                if filetype ~= '' and replay.matches(trigger.pattern, filetype) then
                    return wake(event, buf, filetype)
                end
            elseif BUFFER_EVENTS[event] and is_file_buffer(buf) then
                local name = vim.api.nvim_buf_get_name(buf)
                if matches(trigger.pattern, name) then return wake(event, buf, name) end
            end
        end
    end
end

-- Public API -------------------------------------------------------------------------------

--- Install stubs for `name`. `entry` is a trigger task: { triggers, deferred, deps }. A plugin armed after
--- the events it waits for already happened is loaded at once, see `catch_up`.
function M.register(name, entry)
    local previous = M._plugins[name]
    -- A plugin that is loading or loaded has no stubs left to re-arm.
    if previous and (previous.state == 'loading' or previous.state == 'loaded') then return end
    if previous then disarm(previous) end
    local plugin = {
        name = name,
        triggers = entry.triggers,
        deferred = entry.deferred or {},
        deps = entry.deps or {},
        state = 'waiting',
        commands = {},
        keymaps = {},
    }
    M._plugins[name] = plugin
    arm(plugin)
    vim.schedule(function() catch_up(plugin) end)
end

function M.state(name)
    local plugin = M._plugins[name]
    return plugin and plugin.state
end

-- Claims `name` and every still-waiting dependency, dependencies first.
local function claim(name, claimed)
    local plugin = M._plugins[name]
    if not plugin or plugin.state ~= 'waiting' then return end
    plugin.state = 'loading'
    disarm(plugin)
    for _, dep in ipairs(plugin.deps) do
        claim(dep, claimed)
    end
    table.insert(claimed, plugin)
end

--- Load `name` now. `prepare`, when given, returns the function to run once the load succeeds.
function M.load(name, prepare)
    local claimed = {}
    claim(name, claimed)
    if #claimed == 0 then return end
    local again = prepare and prepare()
    for _, plugin in ipairs(claimed) do
        tasks.enqueue(plugin.name, { deps = plugin.deps, tasks = plugin.deferred }, { append = true })
    end
    tasks.run_all(function()
        for _, plugin in ipairs(claimed) do
            plugin.state = tasks.plugin_failed(plugin.name) and 'failed' or 'loaded'
        end
        if again and M._plugins[name].state == 'loaded' then again() end
    end, { quiet = true, append = true })
end

--- Remove every stub and forget every registered plugin.
function M.clear_all()
    for _, plugin in pairs(M._plugins) do
        disarm(plugin)
    end
    M._plugins = {}
end

return M
