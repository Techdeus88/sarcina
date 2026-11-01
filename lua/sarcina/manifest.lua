-- sarcina/manifest.lua
-- Loads plugin specifications from files.
-- Default location: lua/plugins/**/*.lua (relative to your config dir).
-- Users may optionally set `vim.g.sarcina_spec_paths` to a string or list of additional directories.
-- Each spec file can return a single table or a list of tables.
-- The first numeric entry of a spec (if a string) is treated as a shorthand `repo` value.

local M = {}

local ui = require('sarcina.ui')

-- Default directory for per‑plugin spec files.
local DEFAULT_SPEC_DIR = vim.fn.stdpath('config') .. '/lua/plugins'

-- Resolve directories to scan (default + any user‑provided paths).
-- Helper to detect an array‑like table (list of specs)
local function is_list(t)
    if type(t) ~= 'table' then return false end
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= 'number' then return false end
        count = count + 1
    end
    -- Ensure keys are a consecutive sequence starting at 1
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true
end

-- Every *.lua file under the directories, once each: the default dir may also be passed as an extra.
local function spec_files(dirs)
    local files, seen = {}, {}
    for _, dir in ipairs(dirs) do
        for _, file in ipairs(vim.fn.globpath(dir, '**/*.lua', true, true)) do -- absolute paths
            local real = vim.uv.fs_realpath(file) or file
            if not seen[real] then
                seen[real] = true
                table.insert(files, file)
            end
        end
    end
    return files
end

--- Recursively collect the specs from all *.lua files in the given directories.
local function collect_specs_from_dirs(dirs)
    local specs = {}
    for _, file in ipairs(spec_files(dirs)) do
        local ok, data = pcall(dofile, file)
        if ok and data then
            if is_list(data) then
                vim.list_extend(specs, data)
            else
                table.insert(specs, data)
            end
        else
            ui.emit('error', string.format('Failed to load spec file %s: %s', file, data or 'unknown error'))
        end
    end
    return specs
end

local function resolve_spec_dirs(spec_paths)
    local dirs = { DEFAULT_SPEC_DIR }
    local extra = spec_paths

    if extra then
        if type(extra) == 'string' then
            table.insert(dirs, extra)
        elseif type(extra) == 'table' then
            for _, d in ipairs(extra) do
                if type(d) == 'string' then table.insert(dirs, d) end
            end
        end
    end

    -- Normalise and keep only existing directories
    local norm = {}
    for _, d in ipairs(dirs) do
        local p = vim.fs.normalize(d) -- expands '~' and makes absolute
        if vim.fn.isdirectory(p) == 1 then
            table.insert(norm, p)
        else
            ui.emit('warning', string.format('Sarcina spec directory does not exist: %s', d))
        end
    end
    return norm
end

--- Map the shorthand first entry of a spec (`{ 'owner/repo', ... }`) to `repo`.
function M.expand_shorthand(spec)
    if not spec.repo and type(spec[1]) == 'string' then
        spec.repo = spec[1]
        spec[1] = nil
    end
end

--- Load all specs and normalise the optional shorthand `repo`.
function M.load(opts)
    opts = opts or {}
    local dirs = resolve_spec_dirs(opts.spec_paths)
    local specs = collect_specs_from_dirs(dirs)
    for _, spec in ipairs(specs) do
        M.expand_shorthand(spec)
    end
    if #specs == 0 then
        ui.emit(
            'warn',
            'No plugin specs found – ensure files are in lua/plugins or set vim.g.sarcina_spec_paths'
        )
    end
    return specs
end

return M
