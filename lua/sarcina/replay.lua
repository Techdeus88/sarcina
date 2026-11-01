-- sarcina/replay.lua
-- Repeats what woke a plugin once the plugin has loaded: an event runs only the autocmds the plugin
-- added, a command runs again with its args, bang, range and modifiers, a key is fed again.
-- Each function returns a `prepare`. Call it once the stubs are gone and before loading; it returns
-- the function that replays the trigger after the load.

local ui = require('sarcina.ui')

local M = {}

local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then ui.emit('error', string.format('%s failed: %s', label, err)) end
end

local function pattern_matches(pattern, match)
    return vim.fn.match(match or '', vim.fn.glob2regpat(pattern)) >= 0
end

local function autocmd_key(au)
    return au.id or table.concat({ tostring(au.group), au.pattern, tostring(au.command) }, '\0')
end

local function snapshot_autocmds(event)
    local seen = {}
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
        seen[autocmd_key(au)] = true
    end
    return seen
end

-- Only autocmds that appeared since `seen` run again, so other plugins' handlers never fire twice.
local function replay_autocmds(event, args, seen)
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
        local applies = au.buflocal and au.buf == args.buf
            or not au.buflocal and pattern_matches(au.pattern, args.match)
        if applies and not seen[autocmd_key(au)] then
            if type(au.callback) == 'function' then
                try('Replaying ' .. event, au.callback, args)
            elseif au.command and au.command ~= '' then
                try(
                    'Replaying ' .. event,
                    vim.api.nvim_buf_call,
                    args.buf,
                    function() vim.cmd(au.command) end
                )
            end
        end
    end
end

-- Each `prepare` runs once the stubs are gone and returns the function that replays the trigger.
function M.event(event, args)
    return function()
        local seen = snapshot_autocmds(event)
        return function() replay_autocmds(event, args, seen) end
    end
end

function M.command(cmd, opts)
    return function()
        return function()
            local range
            if opts.range == 2 then
                range = { opts.line1, opts.line2 }
            elseif opts.range == 1 then
                range = { opts.line1 }
            end
            try('Running :' .. cmd, vim.cmd, {
                cmd = cmd,
                args = opts.fargs,
                bang = opts.bang,
                range = range,
                mods = opts.smods,
            })
        end
    end
end

function M.keys(lhs)
    return function()
        return function() vim.api.nvim_feedkeys(vim.keycode(lhs), 'mit', false) end
    end
end

return M
