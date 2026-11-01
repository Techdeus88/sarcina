-- sarcina/resolver.lua
-- Resolves a plugin manifest into an ordered list respecting dependencies.
-- Detects cycles and returns a flat list of {name=..., spec=...} in load order.

local M = {}

local ui = require('sarcina.ui')
local manifest_loader = require('sarcina.manifest')

-- Helper: depth‑first search for topological sort.
local function dfs(name, graph, visited, stack, sorted, path)
    visited[name] = true
    path[name] = true
    local deps = graph[name] or {}
    for _, dep in ipairs(deps) do
        if not visited[dep] then
            if not graph[dep] then
                ui.emit('error', string.format('Plugin %s declares unknown dependency %s', name, dep))
                return false
            end
            if not dfs(dep, graph, visited, stack, sorted, path) then return false end
        elseif path[dep] then
            ui.emit('error', string.format('Circular dependency detected: %s <-> %s', name, dep))
            return false
        end
    end
    path[name] = nil
    table.insert(sorted, name)
    return true
end

-- 'owner/repo' and full URLs both end in the plugin's directory name.
local function derive_name(repo)
    local repo_path = repo:match('([^/]+/[^/]+)$') or repo
    return repo_path:match('([^/]+)$')
end

-- Returns the spec's name, deriving it from `repo` when missing. Emits why and returns nil on failure.
local function name_of(plug)
    if type(plug.name) == 'string' then return plug.name end
    if type(plug.repo) ~= 'string' then
        ui.emit('error', 'Plugin entry missing `name` and cannot infer from `repo`')
        return nil
    end
    local inferred = derive_name(plug.repo)
    if not inferred then
        ui.emit('error', 'Unable to derive plugin name from repo: ' .. plug.repo)
        return nil
    end
    plug.name = inferred
    ui.emit('debug', string.format('Derived plugin name "%s" from repo "%s"', plug.name, plug.repo))
    return inferred
end

--- Resolve the manifest.
--- A dependency is a plugin name, an `owner/repo` (or URL) string, or an inline spec table. The last
--- two join the manifest unless it already has that plugin, and `deps` is rewritten to plain names.
--- @param manifest table List (array) of plugin specs. Each spec must have a unique `name` field.
--- @return table Ordered list of {name=string, spec=table}
function M.resolve(manifest)
    if type(manifest) ~= 'table' then
        ui.emit('error', 'Manifest is not a table')
        return {}
    end

    -- Build lookup maps and dependency graph.
    local name_to_spec = {}
    local repo_to_name = {}
    local graph = {}
    local names = {}

    -- Returns the plugin's name and whether it was new, or nil when it has no usable name.
    local function register(plug)
        local name = name_of(plug)
        if not name then return nil end
        if name_to_spec[name] then return name, false end
        name_to_spec[name] = plug
        graph[name] = {}
        table.insert(names, name)
        if type(plug.repo) == 'string' then repo_to_name[plug.repo] = repo_to_name[plug.repo] or name end
        return name, true
    end

    local function dep_name(dep)
        if type(dep) == 'table' then
            manifest_loader.expand_shorthand(dep)
            return (register(dep))
        end
        if type(dep) ~= 'string' or not dep:find('/', 1, true) then return dep end
        return repo_to_name[dep] or (register({ repo = dep }))
    end

    for _, plug in ipairs(manifest) do
        local name, added = register(plug)
        if not name then return {} end
        if not added then
            ui.emit('warning', 'Duplicate plugin name: ' .. name .. ' – keeping first occurrence')
        end
    end

    -- Populate dependency edges. Dependencies declared by repo or inline are appended to `names`, so the
    -- loop reaches their own dependencies too.
    local expanded = 0
    while expanded < #names do
        expanded = expanded + 1
        local plug = name_to_spec[names[expanded]]
        local deps = plug.deps or plug.dependencies
        if deps then
            if type(deps) ~= 'table' then
                ui.emit('warning', string.format('`deps` for %s should be a list', plug.name))
            else
                local dep_names = {}
                for _, dep in ipairs(deps) do
                    local name = dep_name(dep)
                    if type(name) ~= 'string' then
                        ui.emit(
                            'error',
                            string.format(
                                'Plugin %s has an invalid dependency: %s',
                                plug.name,
                                vim.inspect(dep)
                            )
                        )
                        return {}
                    end
                    table.insert(dep_names, name)
                end
                plug.deps, plug.dependencies = dep_names, nil
                graph[plug.name] = dep_names
            end
        end
    end

    -- Topological sort.
    local visited = {}
    local sorted_names = {}
    for _, name in ipairs(names) do
        if not visited[name] then
            local ok = dfs(name, graph, visited, {}, sorted_names, {})
            if not ok then
                ui.emit('error', 'Dependency resolution failed')
                return {}
            end
        end
    end

    -- Build the ordered result list.
    local ordered = {}
    for _, name in ipairs(sorted_names) do
        table.insert(ordered, { name = name, spec = name_to_spec[name] })
    end
    ui.emit('debug', string.format('Resolved %d plugins (order respects dependencies)', #ordered))

    -- -----------------------------------------------------------------
    -- Generate default tasks for each plugin if not explicitly defined
    -- -----------------------------------------------------------------
    local task_factory = require('sarcina.task_factory')
    for _, entry in ipairs(ordered) do
        if entry.spec.triggers == nil then entry.spec.triggers = task_factory.triggers(entry.spec) end
    end
    -- An eager plugin needs its dependencies loaded up front, so they cannot wait on triggers.
    for i = #ordered, 1, -1 do
        local spec = ordered[i].spec
        local deps = spec.deps or spec.dependencies
        if not spec.triggers and type(deps) == 'table' then
            for _, dep in ipairs(deps) do
                name_to_spec[dep].triggers = false -- false, not nil, so generate() keeps it eager
            end
        end
    end
    for _, entry in ipairs(ordered) do
        local spec = entry.spec
        if not spec.tasks then spec.tasks = task_factory.generate(spec) end
    end

    return ordered
end

return M
