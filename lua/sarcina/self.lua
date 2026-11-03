-- sarcina/self.lua
-- Sarcina's own checkout. It is found from where this file is, so it works wherever Sarcina was installed: by the
-- bootstrap of your config (often inside the plugins directory), by another plugin manager, or as a working copy.
-- The checker looks at it before the plugins, the updater moves it like one, and `clean` and `delete` never take
-- it for a plugin of their own.

local M = {}

--- The name Sarcina has in the Updates list and for `:Sarcina update`.
M.name = 'sarcina'

--- The directory to use instead of the one this file is in; false turns the self-check off. For tests.
M.root = nil

--- The directory Sarcina runs from, or nil when the self-check is off.
function M.dir()
    if M.root == false then return nil end
    if M.root then return M.root end
    local source = debug.getinfo(1, 'S').source:sub(2)
    return vim.fs.normalize(vim.fn.fnamemodify(source, ':p:h:h:h'))
end

--- Whether `dir` is Sarcina's own directory, links resolved.
function M.is(dir)
    local own = M.dir()
    if not own then return false end
    local real = vim.uv.fs_realpath(dir)
    return real ~= nil and real == vim.uv.fs_realpath(own)
end

--- Sarcina as an entry of a resolved manifest, `{ name, timing, spec, dir }`, or nil when its directory is not a
--- git checkout, which nothing could check or update. It follows its remote's default branch.
function M.entry()
    local dir = M.dir()
    if not dir or not vim.uv.fs_stat(dir .. '/.git') then return nil end
    return { name = M.name, timing = 'now', dir = dir, spec = { name = M.name, repo = 'self', self = true } }
end

return M
