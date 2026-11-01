-- sarcina/schema.lua
-- Central validation definitions for Sarcina.
-- Uses Neovim's built‑in vim.validate + a few helpers.
-- Exported API:
--   M.validate_manifest(manifest) → true|false (error messages emitted via UI)
--   M.validate_task(task)       → true|false (error messages emitted via UI)

local M = {}

local ui = require('sarcina.ui')

-----------------------------------------------------------------
-- Helper utilities
-----------------------------------------------------------------
local function is_string(v) return type(v) == 'string' end
local function is_table(v) return type(v) == 'table' end
local function is_function(v) return type(v) == 'function' end

-- Emit a user‑visible error and return false.
local function fail(msg)
    ui.emit('error', '[Schema] ' .. msg)
    return false
end

-----------------------------------------------------------------
-- 1. Manifest validation
-----------------------------------------------------------------
-- A manifest is a *list* (array) of plugin specs.
---@type { key: string, type: string|string[] }[]
local OPTIONAL_FIELDS = {
    { key = 'deps', type = 'table' },
    { key = 'dependencies', type = 'table' },
    { key = 'cmd', type = { 'table', 'string' } },
    { key = 'event', type = { 'table', 'string' } },
    { key = 'ft', type = { 'table', 'string' } },
    { key = 'keys', type = { 'table', 'string' } },
    { key = 'init', type = { 'string', 'function' } },
    { key = 'before', type = { 'string', 'function' } },
    { key = 'build', type = { 'string', 'function' } },
    { key = 'config', type = { 'string', 'function' } },
    { key = 'after', type = { 'string', 'function' } },
    { key = 'opts', type = { 'table', 'function' } },
    { key = 'main', type = 'string' },
}

function M.validate_manifest(manifest)
    if not is_table(manifest) then return fail('Manifest must be a table (list of plugin specs).') end

    for i, plug in ipairs(manifest) do
        if not is_table(plug) then return fail(string.format('Manifest entry #%d is not a table.', i)) end

        -- ---------------------------------------------------------
        -- Required fields (or derived)
        -- ---------------------------------------------------------
        if not plug.name or not is_string(plug.name) then
            -- name can be derived from repo later; we just ensure at least one of them exists.
            if not plug.repo or not is_string(plug.repo) then
                return fail(
                    string.format('Plugin entry #%d must have a `name` (string) or a `repo` (string).', i)
                )
            end
        end

        if not plug.repo or not is_string(plug.repo) then
            return fail(
                string.format('Plugin "%s" missing required `repo` string.', plug.name or '<no-name>')
            )
        end

        -- ---------------------------------------------------------
        -- Optional fields & type checks
        -- ---------------------------------------------------------
        for _, chk in ipairs(OPTIONAL_FIELDS) do
            if plug[chk.key] ~= nil then
                local typ = type(plug[chk.key])
                local expected = chk.type
                if type(expected) == 'table' then
                    local ok = false
                    for _, allowed in ipairs(expected) do
                        if typ == allowed then
                            ok = true
                            break
                        end
                    end
                    if not ok then
                        return fail(
                            string.format(
                                'Plugin "%s": field `%s` must be one of %s, got %s.',
                                plug.name or '<no-name>',
                                chk.key,
                                table.concat(expected, ', '),
                                typ
                            )
                        )
                    end
                else
                    if typ ~= expected then
                        return fail(
                            string.format(
                                'Plugin "%s": field `%s` must be %s, got %s.',
                                plug.name or '<no-name>',
                                chk.key,
                                expected,
                                typ
                            )
                        )
                    end
                end
            end
        end
    end

    ui.emit('debug', '[Schema] Manifest validation succeeded.')
    return true
end

-----------------------------------------------------------------
-- 2. Task validation
-----------------------------------------------------------------
-- Every task must have `id` (string) and `type` (string).
-- Additional fields depend on the type.
local TASK_SPEC = {
    git_clone = { required = { 'repo' } },
    lua = { required = {} }, -- needs `script` or `fn`, checked below
    cmd = { required = { 'cmd' } },
    shell = { required = { 'cmd' } },
    keymaps = { required = { 'keys' } },
    rtp = { required = {} },
    trigger = { required = { 'triggers' } },
    make = { required = {} },
}

function M.validate_task(task)
    if not is_table(task) then return fail('Task is not a table.') end

    if not is_string(task.id) then return fail('Task missing `id` (string).') end
    if not is_string(task.type) then
        return fail(string.format('Task %s missing `type` (string).', task.id))
    end

    local spec = TASK_SPEC[task.type]
    if not spec then return fail(string.format('Task %s has unknown type `%s`.', task.id, task.type)) end

    for _, field in ipairs(spec.required) do
        if task[field] == nil then
            return fail(string.format('Task %s (%s) missing required field `%s`.', task.id, task.type, field))
        end
    end

    if task.type == 'lua' and task.script == nil and task.fn == nil then
        return fail(string.format('Task %s (lua) needs a `script` string or a `fn` function.', task.id))
    end

    -- Minor type checks for common fields
    if task.repo and not is_string(task.repo) then
        return fail(string.format('Task %s: `repo` must be a string.', task.id))
    end
    if task.script and not is_string(task.script) then
        return fail(string.format('Task %s: `script` must be a string.', task.id))
    end
    if task.per_commit ~= nil and type(task.per_commit) ~= 'boolean' then
        return fail(string.format('Task %s: `per_commit` must be a boolean.', task.id))
    end
    if task.cmd and not is_string(task.cmd) then
        return fail(string.format('Task %s: `cmd` must be a string.', task.id))
    end
    if task.fn and not is_function(task.fn) then
        return fail(string.format('Task %s: `fn` must be a function.', task.id))
    end
    if task.keys and not is_table(task.keys) then
        return fail(string.format('Task %s: `keys` must be a table.', task.id))
    end
    if task.triggers and not is_table(task.triggers) then
        return fail(string.format('Task %s: `triggers` must be a table.', task.id))
    end
    if task.opts and not (is_table(task.opts) or is_function(task.opts)) then
        return fail(string.format('Task %s: `opts` must be a table or a function.', task.id))
    end

    -- All good
    return true
end

-----------------------------------------------------------------
-- Exported API
-----------------------------------------------------------------
return M
