-- sarcina/json.lua
-- JSON for the files Sarcina writes, such as the lock file you keep in git: keys in order and two spaces a level,
-- the same text on every Neovim. vim.json.encode takes `indent` and `sort_keys` only from Neovim 0.12 on.

local M = {}

local function encode(value, indent)
    -- Neovim 0.11 escapes a slash, which 0.12 leaves as it is.
    if type(value) ~= 'table' then return (vim.json.encode(value):gsub('\\/', '/')) end
    if next(value) == nil then return '[]' end
    local inner = indent .. '  '
    local items = {}
    if vim.islist(value) then
        for _, item in ipairs(value) do
            table.insert(items, inner .. encode(item, inner))
        end
        return '[\n' .. table.concat(items, ',\n') .. '\n' .. indent .. ']'
    end
    local keys = vim.tbl_keys(value)
    table.sort(keys)
    for _, key in ipairs(keys) do
        table.insert(items, inner .. encode(tostring(key), inner) .. ': ' .. encode(value[key], inner))
    end
    return '{\n' .. table.concat(items, ',\n') .. '\n' .. indent .. '}'
end

--- `value` as JSON, its keys sorted and each level indented two spaces, as `vim.json.encode(value, { indent =
--- '  ', sort_keys = true })` writes it on Neovim 0.12.
function M.encode(value) return encode(value, '') end

return M
