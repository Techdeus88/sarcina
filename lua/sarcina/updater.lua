-- sarcina/updater.lua
-- `check` and `update`: fetch what each plugin's remote has, and for `update` move to it and rebuild what
-- moved. Each plugin is a `git_update` task in the task engine (see executors.lua), so the window shows it,
-- and the lock file is rewritten by the run that did it (see lock.lua).

local confirm = require('sarcina.confirm')
local paths = require('sarcina.paths')
local pins = require('sarcina.pin')
local stats = require('sarcina.stats')
local tasks = require('sarcina.tasks')
local ui = require('sarcina.ui')

local M = {}

local PAST = { check = 'checked', update = 'updated' }

-- The entries of `resolved` that `names` pick, in the resolver's order, or nil after saying which name is
-- not a plugin. No names picks them all.
local function select(resolved, names)
    if #names == 0 then return resolved end
    local known, picked, unknown = {}, {}, {}
    for _, entry in ipairs(resolved) do
        known[entry.name] = true
    end
    for _, name in ipairs(names) do
        if known[name] then
            picked[name] = true
        else
            table.insert(unknown, name)
        end
    end
    if #unknown > 0 then
        ui.emit('error', 'Unknown plugin: ' .. table.concat(unknown, ', '))
        return nil
    end
    return vim.tbl_filter(function(entry) return picked[entry.name] end, resolved)
end

local function installed(entry) return vim.uv.fs_stat(paths.install(entry.name)) ~= nil end

-- `resolved` with Sarcina itself first, which checks and updates like a plugin (see self.lua), unless it is off or a
-- spec already names it or its directory.
local function with_self(resolved)
    local self = require('sarcina.self')
    local own = self.entry()
    if not own then return resolved end
    for _, entry in ipairs(resolved) do
        if entry.name == own.name or self.is(paths.install(entry.name)) then return resolved end
    end
    paths.set_dir(own.name, own.dir)
    return vim.list_extend({ own }, resolved)
end

-- A plugin's tasks for the run: the fetch, and for an update the plugin's own build, which `per_commit` runs
-- only when the plugin moved. The fetches start together and every build waits for all of them.
local function plan(entry, mode)
    local list = {
        {
            id = mode,
            type = 'git_update',
            apply = mode == 'update',
            pin = pins.of(entry.spec),
            phase = 'install',
        },
    }
    if mode == 'update' then
        for _, task in ipairs(entry.spec.tasks or {}) do
            if task.id == 'build' then table.insert(list, task) end
        end
    end
    return list
end

--- What a finished run says, and at what level: the plugins that have an update (check) or got one (update),
--- those that were left alone, and those that failed.
function M.summarize(mode, jobs)
    local moved, left, failed, current = {}, {}, {}, 0
    for _, job in ipairs(jobs) do
        if job.id == mode then
            local note = job.note or ''
            if job.status == 'failed' then
                table.insert(failed, job.plugin .. ' (' .. (job.error or 'failed') .. ')')
            elseif note == 'up to date' then
                current = current + 1
            elseif vim.startswith(note, 'skipped') then
                table.insert(left, job.plugin .. ' (' .. note .. ')')
            elseif job.status == 'done' then
                table.insert(moved, job.plugin .. ' ' .. note:gsub('^update available ', ''))
            end
        end
    end
    local parts = {}
    if #moved > 0 then
        local head = mode == 'check' and '%d update%s available: ' or 'Updated %d plugin%s: '
        table.insert(parts, head:format(#moved, #moved == 1 and '' or 's') .. table.concat(moved, ', '))
        table.insert(parts, mode == 'check' and 'Run :Sarcina update.' or 'Restart Neovim to load them.')
    elseif #left == 0 and #failed == 0 then
        table.insert(parts, current == 0 and 'No plugin to ' .. mode or 'Everything is up to date.')
    end
    if #left > 0 then table.insert(parts, 'Left alone: ' .. table.concat(left, ', ') .. '.') end
    if #failed > 0 then table.insert(parts, 'Failed: ' .. table.concat(failed, ', ') .. '.') end
    return table.concat(parts, ' '), (#left > 0 or #failed > 0) and 'warn' or 'info'
end

local function run(mode, resolved, names, finish)
    local picked = select(resolved, names)
    if not picked then return end
    -- Every plugin of the manifest stays registered, so the numbers and the window keep counting all of them;
    -- the ones in this run get the plan of the run.
    local plans, missing, local_plugins = {}, {}, {}
    for _, entry in ipairs(picked) do
        -- A plugin with a `dir` is a working copy of yours, so its remote is never pulled into it.
        if entry.spec.dir then
            table.insert(local_plugins, entry.name)
        elseif installed(entry) then
            plans[entry.name] = plan(entry, mode)
        else
            table.insert(missing, entry.name)
        end
    end
    local entries = vim.tbl_map(function(entry)
        local list = plans[entry.name]
        if not list then return entry end
        local spec = vim.tbl_extend('force', {}, entry.spec, { tasks = list })
        return { name = entry.name, timing = entry.timing, spec = spec }
    end, resolved)
    -- Sarcina is no row of the window: its update shows in the Updates list and the header.
    stats.register(vim.tbl_filter(function(entry) return not entry.spec.self end, entries))
    if #missing > 0 then
        ui.emit(
            'warn',
            'Not installed, so not '
                .. PAST[mode]
                .. ': '
                .. table.concat(missing, ', ')
                .. '. Run :Sarcina install.'
        )
    end
    if #local_plugins > 0 and #names > 0 then
        ui.emit(
            'warn',
            'Local plugins are not ' .. PAST[mode] .. ': ' .. table.concat(local_plugins, ', ') .. '.'
        )
    end
    if vim.tbl_isempty(plans) then return end
    for _, entry in ipairs(picked) do
        if plans[entry.name] then
            tasks.enqueue(entry.name, { deps = entry.spec.deps, tasks = plans[entry.name] })
        end
    end
    ui.emit(
        'info',
        string.format('%s %d plugins...', mode == 'check' and 'Checking' or 'Updating', vim.tbl_count(plans))
    )
    tasks.run_all(function()
        local jobs = tasks.snapshot().jobs
        if finish then return finish(jobs) end
        local text, level = M.summarize(mode, jobs)
        ui.emit(level, text)
    end, { quiet = true })
end

--- Fetch what the remote of each plugin has, and say which have an update. `names` picks plugins, none picks all.
function M.check(resolved, names) run('check', with_self(resolved), names or {}) end

-- What a finished look says about `entries`, and at what level: the plugins with an update and the ones whose
-- remote could not say.
local function look_summary(state, entries)
    local found, failed = {}, {}
    for _, entry in ipairs(entries) do
        local info, why = state.updates[entry.name], state.failed[entry.name]
        if info then
            table.insert(
                found,
                string.format('%s %s → %s', entry.name, info.from:sub(1, 7), info.to:sub(1, 7))
            )
        elseif why then
            table.insert(failed, entry.name .. ' (' .. why .. ')')
        end
    end
    local parts = {}
    if #found > 0 then
        table.insert(
            parts,
            string.format('%d update%s available: ', #found, #found == 1 and '' or 's')
                .. table.concat(found, ', ')
                .. '.'
        )
        table.insert(parts, 'Run :Sarcina update.')
    elseif #failed == 0 then
        table.insert(parts, 'Everything is up to date.')
    end
    if #failed > 0 then table.insert(parts, 'Failed: ' .. table.concat(failed, ', ') .. '.') end
    return table.concat(parts, ' '), #failed > 0 and 'warn' or 'info'
end

--- Look for updates in the background (see checker.lua), without the task list: the window lists them in its
--- Updates section, and a message says which plugins have one when it is done. Nothing moves. `names` picks
--- plugins, none picks all; a look at some keeps what an earlier one found for the others.
function M.look(resolved, names)
    names = names or {}
    local picked = select(with_self(resolved), names)
    if not picked then return end
    local checker = require('sarcina.checker')
    if checker.state().running then return ui.emit('info', 'Already checking for updates') end
    local wanted, missing, local_plugins = {}, {}, {}
    for _, entry in ipairs(picked) do
        if entry.spec.dir then
            table.insert(local_plugins, entry.name)
        elseif installed(entry) then
            table.insert(wanted, entry)
        else
            table.insert(missing, entry.name)
        end
    end
    if #missing > 0 then
        ui.emit(
            'warn',
            'Not installed, so not checked: ' .. table.concat(missing, ', ') .. '. Run :Sarcina install.'
        )
    end
    if #local_plugins > 0 and #names > 0 then
        ui.emit('warn', 'Local plugins are not checked: ' .. table.concat(local_plugins, ', ') .. '.')
    end
    if #wanted == 0 then return end
    ui.emit('info', string.format('Checking %d plugin%s...', #wanted, #wanted == 1 and '' or 's'))
    checker.run(wanted, function(state)
        local text, level = look_summary(state, wanted)
        ui.emit(level, text)
    end, { keep = #names > 0 })
end

-- The plugins a finished check found a newer commit for, with what to say about each.
local function available(jobs)
    local names, lines = {}, {}
    for _, job in ipairs(jobs) do
        local change = job.id == 'check'
            and job.status == 'done'
            and (job.note or ''):match('^update available (.+)$')
        if change then
            table.insert(names, job.plugin)
            table.insert(lines, job.plugin .. ' ' .. change)
        end
    end
    return names, lines
end

--- Fetch and move each plugin to it, rebuild what moved, and write the lock file. With the question on, it
--- checks first and asks before it changes anything, naming the plugins that have a newer commit.
function M.update(resolved, names)
    names = names or {}
    resolved = with_self(resolved)
    if not confirm.enabled then return run('update', resolved, names) end
    run('check', resolved, names, function(jobs)
        local moving, lines = available(jobs)
        if #moving == 0 then
            local text, level = M.summarize('check', jobs)
            return ui.emit(level, text)
        end
        local prompt = string.format(
            'Update %d plugin%s?\n%s',
            #moving,
            #moving == 1 and '' or 's',
            table.concat(lines, '\n')
        )
        confirm.ask(prompt, function(yes)
            if not yes then return ui.emit('info', 'Nothing updated') end
            run('update', resolved, moving)
        end)
    end)
end

return M
