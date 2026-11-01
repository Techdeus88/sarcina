-- sarcina/resolver.lua
-- Resolves a plugin manifest into an ordered list respecting dependencies.
-- Detects cycles and returns a flat list of {name=..., spec=...} in load order.

local M = {}

local ui = require('sarcina.ui')

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

--- Resolve the manifest.
--- @param manifest table List (array) of plugin specs. Each spec must have a unique `name` field.
--- @return table Ordered list of {name=string, spec=table}
function M.resolve(manifest)
    if type(manifest) ~= 'table' then
        ui.emit('error', 'Manifest is not a table')
        return {}
    end

    -- Build lookup map and dependency graph.
    local name_to_spec = {}
    local graph = {}
    local names = {}
    for _, plug in ipairs(manifest) do
        if not plug.name or type(plug.name) ~= 'string' then
            -- Derive a default name from the repo URL if present
            if plug.repo and type(plug.repo) == 'string' then
                -- Strip possible protocol (e.g., https://github.com/owner/repo)
                local repo_path = plug.repo:match('([^/]+/[^/]+)$') or plug.repo
                local inferred = repo_path:match('([^/]+)$')
                if inferred then
                    plug.name = inferred
                    ui.emit(
                        'debug',
                        string.format('Derived plugin name "%s" from repo "%s"', plug.name, plug.repo)
                    )
                else
                    ui.emit('error', 'Unable to derive plugin name from repo: ' .. plug.repo)
                    return {}
                end
            else
                ui.emit('error', 'Plugin entry missing `name` and cannot infer from `repo`')
                return {}
            end
        end
        if name_to_spec[plug.name] then
            ui.emit('warning', 'Duplicate plugin name: ' .. plug.name .. ' – keeping first occurrence')
        else
            name_to_spec[plug.name] = plug
            graph[plug.name] = {}
            table.insert(names, plug.name)
        end
    end

    -- Populate dependency edges.
    for _, plug in ipairs(manifest) do
        local deps = plug.deps or plug.dependencies
        if deps then
            if type(deps) ~= 'table' then
                ui.emit('warning', string.format('`deps` for %s should be a list', plug.name))
            else
                for _, dep in ipairs(deps) do
                    table.insert(graph[plug.name], dep)
                end
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
