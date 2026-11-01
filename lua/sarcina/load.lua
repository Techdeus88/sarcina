-- sarcina/load.lua
-- When code runs. `now` runs it inline, before the UI exists. `later` queues it for after `UIEnter`
-- (after `VimEnter` when no UI attaches), one callback per 1 ms timer tick, so the editor handles input and
-- redraws in between instead of running them all in one batch, as MiniMisc and MiniDeps do.
-- `event:`, `ft:`, `keys:` and `cmd:` run it once, when they fire, then repeat what fired them. Every
-- callback runs under `safely`: an error is reported and never stops the callbacks after it.

local replay = require('sarcina.replay')
local ui = require('sarcina.ui')

local M = {}

local ready = false -- when startup ended (an hrtime): UIEnter, or VimEnter with no UI
local draining = false
local generation = 0 -- bumped by a reset, so a timer left over from before it stops
local queue = {} -- `later` callbacks, { f, trace }, in the order received
local held = {} -- errors from before startup ended, shown once the UI is up

local function report(err)
    if ready then
        ui.emit('error', err)
    else
        table.insert(held, err)
    end
end

-- `trace` says where a deferred callback was queued, since its own traceback starts in the event loop.
local function run(f, trace)
    local ok, err = xpcall(f, debug.traceback)
    if not ok then report(trace and (err .. '\n\nQueued from:' .. trace) or err) end
    return ok
end

-- Runs the queue one callback per 1 ms timer tick. A chain of vim.schedule calls would drain in one batch,
-- and the editor would not see input or a redraw until the last callback was done.
local function drain()
    if draining or not ready then return end
    draining = true
    local mine = generation
    local timer = assert(vim.uv.new_timer())
    local step
    step = vim.schedule_wrap(function()
        local item = mine == generation and table.remove(queue, 1) or nil
        if not item then
            if mine == generation then draining = false end
            if not timer:is_closing() then timer:close() end
            return
        end
        run(item.f, item.trace)
        timer:start(1, 0, step)
    end)
    timer:start(1, 0, step)
end

local function open()
    if ready then return end
    ready = vim.uv.hrtime()
    for _, err in ipairs(held) do
        ui.emit('error', err)
    end
    held = {}
    drain()
end

if vim.v.vim_did_enter == 1 then
    ready = vim.uv.hrtime()
else
    local group = vim.api.nvim_create_augroup('sarcina_load', { clear = true })
    vim.api.nvim_create_autocmd('UIEnter', { group = group, once = true, callback = open })
    vim.api.nvim_create_autocmd('VimEnter', {
        group = group,
        once = true,
        callback = function()
            if #vim.api.nvim_list_uis() == 0 then open() end
        end,
    })
end

--- Run `f` now, inline. Returns whether it succeeded.
function M.now(f) return run(f) end

--- Run `f` after the UI is up, after the callbacks queued before it.
local function enqueue(f, trace)
    table.insert(queue, { f = f, trace = trace })
    drain()
end

function M.later(f) enqueue(f, debug.traceback('', 2)) end

--- `now` when Neovim started with file arguments, otherwise `later`.
function M.now_if_args(f)
    if vim.fn.argc(-1) > 0 then return M.now(f) end
    enqueue(f, debug.traceback('', 2))
end

-- Runs `f` between the preparation and the replay of a trigger. The trigger only repeats after a success.
local function with_replay(prepare, f, trace)
    local again = prepare()
    if run(f, trace) then again() end
end

-- One autocmd for all the events. It is deleted before `f` runs, so `f` runs exactly once, whichever event
-- comes first, and a nested event cannot run it again. `nested` lets the events that `f` causes run their handlers.
local function once_on(events, pattern, make_prepare, f, trace)
    local id
    id = vim.api.nvim_create_autocmd(events, {
        pattern = pattern,
        nested = true,
        callback = function(args)
            pcall(vim.api.nvim_del_autocmd, id)
            with_replay(make_prepare(args), f, trace)
        end,
    })
end

local LOADERS = {
    -- 'event:BufRead,BufNew *.lua': the events, comma separated, and an optional pattern.
    event = function(what, f, trace)
        local events, pattern = what:match('^(%S+)%s+(.+)$')
        events = vim.split(events or what, ',', { trimempty = true })
        once_on(events, pattern, function(args) return replay.event(args.event, args) end, f, trace)
    end,
    -- 'ft:lua,vim': the filetypes, comma separated.
    ft = function(what, f, trace)
        local filetypes = vim.split(what, ',', { trimempty = true })
        once_on('FileType', filetypes, function(args) return replay.event('FileType', args) end, f, trace)
    end,
    cmd = function(name, f, trace)
        vim.api.nvim_create_user_command(name, function(opts)
            pcall(vim.api.nvim_del_user_command, name)
            with_replay(replay.command(name, opts), f, trace)
        end, { nargs = '*', bang = true, range = true })
    end,
    -- 'keys:<lhs>' maps in normal mode; 'keys:nv <lhs>' names the modes first.
    keys = function(what, f, trace)
        local modes, lhs = what:match('^([nvxsoilct!]+)%s+(.+)$')
        modes, lhs = vim.split(modes or 'n', ''), lhs or what
        vim.keymap.set(modes, lhs, function()
            pcall(vim.keymap.del, modes, lhs)
            with_replay(replay.keys(lhs), f, trace)
        end, { silent = true, desc = 'sarcina: load, then ' .. lhs })
    end,
}

--- Run `f` at `when`: 'now', 'later', 'now_if_args', or a trigger that runs it once and then repeats
--- what fired it: 'event:<Event[,Event]> [pattern]', 'ft:<filetype[,filetype]>', 'keys:[modes ]<lhs>',
--- 'cmd:<Command>'. An error in `f` is reported with the place `safely` was called from.
function M.safely(when, f)
    if when == 'now' then return M.now(f) end
    local trace = debug.traceback('', 2)
    if when == 'later' then return enqueue(f, trace) end
    if when == 'now_if_args' then
        if vim.fn.argc(-1) > 0 then return M.now(f) end
        return enqueue(f, trace)
    end
    local kind, what = tostring(when):match('^(%a+):(.+)$')
    local loader = kind and LOADERS[kind]
    if not loader then return report('Unknown load time: ' .. tostring(when)) end
    local ok, err = pcall(loader, what, f, trace)
    if not ok then report('Could not set up ' .. tostring(when) .. ': ' .. tostring(err)) end
end

--- The hrtime at which startup ended, or nil while the UI is not up yet.
function M.ready_at() return ready or nil end

--- True when no `later` callback is queued or running.
function M.idle() return #queue == 0 and not draining end

--- Forget the queue and the held errors, and set whether startup is over. For tests.
function M._reset(is_ready)
    generation = generation + 1
    queue, held, draining = {}, {}, false
    ready = is_ready ~= false and vim.uv.hrtime()
end

--- Pretend startup is over. For tests.
function M._open() open() end

return M
