-- sarcina/task_factory.lua
-- Generates a default ordered list of tasks for a plugin spec.
-- Users can provide custom fields (build, triggers, opts, config, main, etc.)
-- without explicitly writing a `tasks` list. This module translates those
-- shorthand fields into the normalized task structures that the task engine
-- understands.

local main_module = require('sarcina.main_module')

local M = {}

local function as_list(value)
    if value == nil or type(value) == 'table' then return value end
    return { value }
end

--- Normalize a spec's event/ft/cmd/keys into lists. Returns nil when it has none.
function M.triggers(spec)
    local triggers = {
        event = as_list(spec.event),
        ft = as_list(spec.ft),
        cmd = as_list(spec.cmd),
        keys = as_list(spec.keys),
    }
    if next(triggers) == nil then return nil end
    return triggers
end

-- A string runs as a Lua chunk, or as an Ex command when it starts with ':'; a function is kept as a closure.
local function lua_task(id, value, opts)
    if type(value) == 'string' and value:sub(1, 1) == ':' then
        return { id = id, type = 'cmd', cmd = value:sub(2) }
    end
    local task = { id = id, type = 'lua', opts = opts }
    if type(value) == 'function' then
        task.fn = value
    elseif type(value) == 'string' then
        task.script = value
    end
    return task
end

local function repo_name(repo)
    local base = repo and repo:match('([^/]+)$')
    return base and (base:gsub('%.git$', ''))
end

local function candidate_names(spec)
    local names = {}
    for _, name in ipairs({ spec.name or false, repo_name(spec.repo) or false }) do
        if name then table.insert(names, name) end
    end
    return names
end

-- `config` wins. Otherwise `opts` or `main` requires the plugin's main module and calls setup(opts).
local function load_task(spec)
    if spec.config then return lua_task('load', spec.config, spec.opts) end
    if spec.main == nil and spec.opts == nil then return nil end
    local main, names = spec.main, candidate_names(spec)
    return lua_task('load', function(plugin, opts)
        local module = main
        if not module then
            local err
            module, err = main_module.find(plugin.dir, vim.list_extend({ plugin.name }, names))
            if not module then error(err, 0) end
        end
        local loaded = require(module)
        if opts ~= nil then
            if type(loaded) ~= 'table' or type(loaded.setup) ~= 'function' then
                error(module .. ' has no setup() to receive opts', 0)
            end
            loaded.setup(opts)
        end
    end, spec.opts)
end

-- Task order: before, install, build, then rtp, load, after. A lazy plugin swaps the last three
-- for one load_trigger task that carries them and runs them when a trigger fires.
function M.generate(spec)
    local triggers = spec.triggers
    if triggers == nil then triggers = M.triggers(spec) end
    local lazy = type(triggers) == 'table'
    local tasks = {}

    local before = spec.init or spec.before
    if before then table.insert(tasks, lua_task('before', before)) end

    if spec.repo then table.insert(tasks, { id = 'install', type = 'git_clone', repo = spec.repo }) end

    if spec.build then
        local build = lua_task('build', spec.build)
        build.per_commit = true
        table.insert(tasks, build)
    end

    local loading = { { id = 'rtp', type = 'rtp' } }
    local load = load_task(spec)
    if load then table.insert(loading, load) end
    if spec.after then table.insert(loading, lua_task('after', spec.after)) end

    if lazy then
        table.insert(tasks, {
            id = 'load_trigger',
            type = 'trigger',
            triggers = triggers,
            deferred = loading,
            deps = spec.deps or spec.dependencies,
        })
    else
        vim.list_extend(tasks, loading)
    end

    return tasks
end

return M
