-- sarcina/load.lua
-- When code runs. `now` runs it inline, before the UI exists. `later` queues it for after `UIEnter`
-- (after `VimEnter` when no UI attaches), one callback per tick, so the screen can paint in between.
-- `event:` and `filetype:` run it once, when they fire. Every callback runs under `safely`: an
-- error is reported and never stops the callbacks after it.

local ui = require('sarcina.ui')

local M = {}

local ready = false -- startup is over: UIEnter, or VimEnter with no UI
local draining = false
local queue = {} -- `later` callbacks, in the order received
local held = {} -- errors from before startup ended, shown once the UI is up

local function report(err)
    if ready then
        ui.emit('error', err)
    else
        table.insert(held, err)
    end
end

local function run(f)
    local ok, err = xpcall(f, debug.traceback)
    if not ok then report(err) end
    return ok
end

local function drain()
    if draining or not ready then return end
    draining = true
    local function step()
        local f = table.remove(queue, 1)
        if not f then
            draining = false
            return
        end
        run(f)
        vim.schedule(step)
    end
    vim.schedule(step)
end

local function open()
    if ready then return end
    ready = true
    for _, err in ipairs(held) do
        ui.emit('error', err)
    end
    held = {}
    drain()
end

if vim.v.vim_did_enter == 1 then
    ready = true
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
function M.later(f)
    table.insert(queue, f)
    drain()
end

--- `now` when Neovim started with file arguments, otherwise `later`.
function M.now_if_args(f)
    if vim.fn.argc(-1) > 0 then return M.now(f) end
    M.later(f)
end

--- Run `f` at `when`: 'now', 'later', 'now_if_args', 'event:<Event> [pattern]' or 'filetype:<ft>'.
function M.safely(when, f)
    if when == 'now' then return M.now(f) end
    if when == 'later' then return M.later(f) end
    if when == 'now_if_args' then return M.now_if_args(f) end
    local kind, what = tostring(when):match('^(%a+):(.+)$')
    local fire = function() run(f) end -- returns nothing, so the autocmd is not deleted early
    if kind == 'event' then
        local event, pattern = what:match('^(%S+)%s+(.+)$')
        vim.api.nvim_create_autocmd(event or what, { pattern = pattern, once = true, callback = fire })
    elseif kind == 'filetype' then
        vim.api.nvim_create_autocmd('FileType', { pattern = what, once = true, callback = fire })
    else
        report('Unknown load time: ' .. tostring(when))
    end
end

--- True when no `later` callback is queued or running.
function M.idle() return #queue == 0 and not draining end

--- Forget the queue and the held errors, and set whether startup is over. For tests.
function M._reset(is_ready)
    queue, held, draining = {}, {}, false
    ready = is_ready ~= false
end

--- Pretend startup is over. For tests.
function M._open() open() end

return M
