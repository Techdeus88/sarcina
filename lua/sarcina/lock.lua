-- sarcina/lock.lua
-- The lock file: the commit of every plugin sarcina installed or updated, in `sarcina-lock.json` in the
-- config directory, so it can be committed with your specs:
--   { "telescope.nvim": { "commit": "<full sha>" } }
-- A fresh clone checks out the commit named here (see git_clone in executors.lua), and every run that
-- cloned or updated a plugin rewrites its entry. The other entries are kept.

local paths = require('sarcina.paths')
local ui = require('sarcina.ui')

local M = {}

local cache -- plugin name -> { commit }, as last read or written
local marked = {} -- plugin name -> its directory, for the plugins that changed since the last flush
local warned = false
local unreadable = false -- the last read found a file that is not valid JSON, such as one with merge markers

local function read()
    local file = io.open(paths.lock_file(), 'r')
    local data = {}
    unreadable = false
    if file then
        local ok, decoded = pcall(vim.json.decode, file:read('*a'))
        file:close()
        if ok and type(decoded) == 'table' then
            data = decoded
        else
            unreadable = true
        end
    end
    return data
end

-- Writes through a temporary file, so a crash cannot leave half of it. Warns once when it cannot.
local function write(data)
    local ok, text = pcall(vim.json.encode, data, { indent = '  ', sort_keys = true })
    if not ok then text = vim.json.encode(data) end
    local path = paths.lock_file()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    -- Replacing a file that could not be read loses its pins, so keep a copy and say so.
    if unreadable then
        unreadable = false
        if vim.uv.fs_copyfile(path, path .. '.bak') then
            ui.emit(
                'warning',
                'The lock file was not valid JSON; it was replaced and the old one kept as ' .. path .. '.bak'
            )
        end
    end
    local file = io.open(path .. '.tmp', 'w')
    local renamed = false
    if file then
        file:write(text, '\n')
        file:close()
        renamed = vim.uv.fs_rename(path .. '.tmp', path) == true
    end
    if renamed then
        cache = data
    elseif not warned then
        warned = true
        ui.emit('warning', 'Could not write the lock file ' .. path)
    end
    return renamed
end

--- The commit the lock file names for a plugin, or nil. A file that is missing or cannot be read has none.
function M.get(name)
    cache = cache or read()
    local entry = cache[name]
    return type(entry) == 'table' and entry.commit or nil
end

--- `name`, cloned or updated into `dir`, is to be written to the lock file at the next `flush`.
function M.mark(name, dir) marked[name] = dir end

--- Writes the commit (`HEAD`) of every marked plugin to the lock file, keeping the other entries. The commits
--- are read in parallel. `done(ok)` runs when the file is written, or at once when nothing was marked.
function M.flush(done)
    local pending = marked
    marked = {}
    local names = vim.tbl_keys(pending)
    if #names == 0 then
        if done then done(true) end
        return
    end
    local found, waiting = {}, #names
    local function finished()
        waiting = waiting - 1
        if waiting > 0 then return end
        local data = read()
        for name, commit in pairs(found) do
            data[name] = { commit = commit }
        end
        local ok = write(data)
        if done then done(ok) end
    end
    for _, name in ipairs(names) do
        local spawned = pcall(
            vim.system,
            { 'git', '-C', pending[name], 'rev-parse', 'HEAD' },
            { text = true },
            function(res)
                if res.code == 0 then found[name] = vim.trim(res.stdout) end
                vim.schedule(finished)
            end
        )
        if not spawned then vim.schedule(finished) end
    end
end

--- Drop the entries of plugins that were removed.
function M.forget(names)
    local data = read()
    local changed = false
    for _, name in ipairs(names) do
        if data[name] ~= nil then
            data[name], changed = nil, true
        end
    end
    if changed then write(data) end
end

--- Forget what was read, marked and warned about. For tests.
function M._reset()
    cache, marked, warned, unreadable = nil, {}, false, false
end

return M
