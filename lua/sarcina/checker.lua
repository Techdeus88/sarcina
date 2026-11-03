-- sarcina/checker.lua
-- Looks for updates in the background, for the Updates section of the window: for each installed plugin it
-- asks the remote where the plugin should be, and for the ones that are behind it fetches the commits in
-- between (see executors.look_ahead). It runs outside the task engine, so the rows of the window keep their
-- state, and it never moves a plugin; `:Sarcina update` does that.

local executors = require('sarcina.executors')
local paths = require('sarcina.paths')
local pins = require('sarcina.pin')
local ui = require('sarcina.ui')

local M = {}

M.max_concurrent = 8
-- An open of the window this soon (ms) after a check finished shows that check instead of starting another.
M.fresh_for = 5 * 60 * 1000

-- `updates` maps a plugin name to what look_ahead said about it: `{ from, to, commits }`.
local state = { running = false, checked = 0, total = 0, updates = {}, failed = {}, finished = nil }
local last_full -- when a check of every plugin last finished, from vim.uv.now()

--- Whether a check is running, how far it got (`checked` of `total`), what it found so far (`updates`, by
--- plugin name), the plugins whose remote could not say (`failed`, name -> why), and when it last finished
--- (`finished`, from vim.uv.now()). Read it, do not change it.
function M.state() return state end

--- What the last check found for a plugin, or nil.
function M.update_of(name) return state.updates[name] end

--- Whether a check of every plugin finished less than `fresh_for` ago.
function M.fresh() return last_full ~= nil and vim.uv.now() - last_full < M.fresh_for end

-- The plugins there is something to check for: cloned by sarcina, and on disk, and Sarcina itself.
local function checkable(entries)
    return vim.tbl_filter(function(entry)
        if entry.dir then return true end
        local spec = entry.spec or {}
        return spec.repo ~= nil and not spec.dir and vim.uv.fs_stat(paths.install(entry.name)) ~= nil
    end, entries)
end

-- Sarcina, to check before the plugins (see self.lua), unless it is off or one of `entries` is it already.
local function own_entry(entries)
    local own = require('sarcina.self').entry()
    if not own then return nil end
    for _, entry in ipairs(entries) do
        if entry.name == own.name or entry.dir then return nil end
    end
    return own
end

--- Check every plugin of `entries` ({ name, spec, dir? }, every registered plugin when nil), up to
--- `max_concurrent` at a time. Sarcina itself is checked first, alone, when `entries` is nil or holds it (see
--- self.lua). Does nothing while a check runs. Each answer emits `updates`, and so does the start and the end;
--- `on_done(state)` runs at the end. `opts.keep` keeps what the last check found for the plugins this one does not
--- check, as for a check of the plugins you name.
function M.run(entries, on_done, opts)
    if state.running then return end
    local everything = entries == nil
    local queue = checkable(entries or require('sarcina.stats').specs())
    local own = everything and own_entry(queue)
    if own then table.insert(queue, 1, own) end
    local first = queue[1] and queue[1].dir and table.remove(queue, 1)
    local updates, failed = {}, {}
    if opts and opts.keep then
        updates, failed = vim.deepcopy(state.updates), vim.deepcopy(state.failed)
        for _, entry in ipairs(vim.list_extend({ first or nil }, queue)) do
            updates[entry.name], failed[entry.name] = nil, nil
        end
    end
    state = {
        running = true,
        checked = 0,
        total = #queue + (first and 1 or 0),
        updates = updates,
        failed = failed,
        finished = nil,
    }
    local current = state
    ui.emit('updates', state)
    local next_index, active = 1, 0
    local function finish()
        current.running = false
        current.finished = vim.uv.now()
        if everything then last_full = current.finished end
        ui.emit('updates', current)
        if on_done then on_done(current) end
    end
    -- Looks at one entry, then calls `after`.
    local function look(entry, after)
        local dir = entry.dir or paths.install(entry.name)
        executors.look_ahead(dir, pins.of(entry.spec), function(info, why)
            current.checked = current.checked + 1
            if info then
                current.updates[entry.name] = info
            elseif info == false then
                current.failed[entry.name] = why
            end
            ui.emit('updates', current)
            after()
        end)
    end
    local pump
    function pump()
        while active < M.max_concurrent and next_index <= #queue do
            local entry = queue[next_index]
            next_index = next_index + 1
            active = active + 1
            look(entry, function()
                active = active - 1
                pump()
            end)
        end
        if active == 0 and next_index > #queue and current.running then finish() end
    end
    if first then
        look(first, pump)
    else
        pump()
    end
end

--- `name` was updated: it has no update any more, and the window lists it in its section only.
function M.settled(name)
    if state.updates[name] == nil then return end
    state.updates[name] = nil
    ui.emit('updates', state)
end

--- Forget what was found. For tests.
function M._reset()
    state = { running = false, checked = 0, total = 0, updates = {}, failed = {}, finished = nil }
    last_full = nil
end

return M
