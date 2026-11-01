-- sarcina/keys.lua
-- Normalizes one `keys` entry: 'lhs', or { lhs, rhs, mode = 'n', desc = ..., <keymap options> }.
-- An entry with an `rhs` is also a mapping, which the `keymaps` task defines once the plugin loads.

local M = {}

-- Passed to vim.keymap.set for the mapping that `rhs` defines.
local MAP_OPTIONS = {
    'desc',
    'silent',
    'noremap',
    'remap',
    'nowait',
    'expr',
    'unique',
    'script',
    'buffer',
    'replace_keycodes',
}

function M.parse(map)
    if type(map) == 'string' then return { lhs = map, mode = 'n', opts = { silent = true } } end
    local opts = { silent = true }
    for _, name in ipairs(MAP_OPTIONS) do
        if map[name] ~= nil then opts[name] = map[name] end
    end
    return {
        lhs = map.lhs or map[1],
        rhs = map.rhs or map[2],
        mode = map.mode or 'n',
        opts = vim.tbl_extend('force', opts, map.opts or {}),
    }
end

--- Define the mapping of an entry that has an `rhs`; entries without one belong to the plugin.
function M.set(map)
    local key = M.parse(map)
    if key.lhs and key.rhs ~= nil then vim.keymap.set(key.mode, key.lhs, key.rhs, key.opts) end
end

return M
