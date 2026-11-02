-- sarcina/installs.lua
-- How long each plugin took to install and when, kept in a JSON file next to the plugins, so a later
-- session can still say what the install of a plugin that is already on disk took:
--   { "telescope.nvim": { "ms": 2314.5, "at": 1730451225 } }
-- `ms` is the milliseconds the clone took, to a tenth, `at` the unix time it finished.

local paths = require('sarcina.paths')

local M = {}

local cache -- plugin name -> { ms, at }, as last read

local function read()
    local file = io.open(paths.installs_file(), 'r')
    local data = {}
    if file then
        local ok, decoded = pcall(vim.json.decode, file:read('*a'))
        file:close()
        if ok and type(decoded) == 'table' then data = decoded end
    end
    return data
end

--- The record of a plugin's install, `{ ms, at }`, or nil when none was kept. A file that is missing or
--- cannot be read counts as no records.
function M.get(name)
    cache = cache or read()
    return cache[name]
end

--- Keep that the install of `name` took `ms`. The file is read again first, so another Neovim's records
--- survive, and written through a temporary file, so a crash cannot leave half of it. A write that fails
--- is dropped: the records are for display only.
function M.record(name, ms)
    cache = read()
    cache[name] = { ms = math.floor(ms * 10 + 0.5) / 10, at = os.time() }
    local ok, text = pcall(vim.json.encode, cache, { indent = '  ', sort_keys = true })
    if not ok then text = vim.json.encode(cache) end
    local path = paths.installs_file()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local file = io.open(path .. '.tmp', 'w')
    if not file then return end
    file:write(text, '\n')
    file:close()
    vim.uv.fs_rename(path .. '.tmp', path)
end

--- Drop the records of plugins that were removed.
function M.forget(names)
    cache = read()
    local changed = false
    for _, name in ipairs(names) do
        if cache[name] ~= nil then
            cache[name], changed = nil, true
        end
    end
    if not changed then return end
    local ok, text = pcall(vim.json.encode, cache, { indent = '  ', sort_keys = true })
    if not ok then text = vim.json.encode(cache) end
    local path = paths.installs_file()
    local file = io.open(path .. '.tmp', 'w')
    if not file then return end
    file:write(text, '\n')
    file:close()
    vim.uv.fs_rename(path .. '.tmp', path)
end

--- Forget what was read, so the next lookup reads the file again. For tests.
function M._reset() cache = nil end

return M
