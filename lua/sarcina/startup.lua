-- sarcina/startup.lua
-- Splits a resolved manifest into what runs before the UI and what runs after it. An installed
-- plugin gets its `init` hook at once. An installed `now` plugin also loads at once, when everything
-- it depends on has. The rest, installs and builds included, is queued and runs once the UI is up.

local load = require('sarcina.load')
local paths = require('sarcina.paths')
local tasks = require('sarcina.tasks')
local ui = require('sarcina.ui')

local M = {}

-- The tasks that make a plugin load, as opposed to installing or building it.
local LOADING = { rtp = true, load = true, keys = true, after = true }

local function installed(name) return vim.uv.fs_stat(paths.install(name)) ~= nil end

local function deps_loaded(spec, loaded)
    for _, dep in ipairs(type(spec.deps) == 'table' and spec.deps or {}) do
        if not loaded[dep] then return false end
    end
    return true
end

-- Splits a generated task list into what runs at once and what is left for later.
local function split(entry, loaded)
    local now_loads = entry.timing == 'now' and deps_loaded(entry.spec, loaded)
    local inline, remaining = {}, {}
    for _, task in ipairs(entry.spec.tasks) do
        if task.id == 'before' or (now_loads and LOADING[task.id]) then
            table.insert(inline, task)
        elseif task.id ~= 'install' then -- the install is already on disk
            table.insert(remaining, task)
        end
    end
    return inline, remaining, now_loads
end

--- Run the `now` phase and queue the rest. The queued run starts once the UI is up.
function M.start(resolved)
    tasks.begin()
    local loaded = {} -- plugin name -> true once its loading tasks have run
    local count = 0
    for _, entry in ipairs(resolved) do
        local spec, name = entry.spec, entry.name
        local rest = spec.tasks
        if entry.generated and installed(name) then
            local inline, remaining, now_loads = split(entry, loaded)
            if #inline > 0 then
                load.now(function() tasks.run_inline(name, { deps = spec.deps, tasks = inline }) end)
                count = count + 1
                if now_loads and not tasks.plugin_failed(name) then loaded[name] = true end
            end
            rest = remaining
        end
        if #rest > 0 then tasks.enqueue(name, { deps = spec.deps, tasks = rest }, { append = true }) end
    end
    ui.emit('debug', string.format('Ran the first tasks of %d installed plugins before the UI', count))
    load.later(function()
        if not tasks._started then tasks.run_all(nil, { quiet = true, append = true }) end
    end)
end

return M
