local h = require('helpers')
local tasks = require('sarcina.tasks')
local executors = require('sarcina.executors')
local ui = require('sarcina.ui')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

executors.t_twice = function(_, done)
    done(true)
    done(false, 'late')
end
executors.t_throws = function() error('kaput') end
executors.t_sleep = function(_, done)
    vim.defer_fn(function() done(true) end, 20)
end

test('run_all returns before any task has run', function()
    local ran = false
    tasks.enqueue('p', {
        tasks = {
            h.lua('a', function() ran = true end),
        },
    })
    tasks.run_all()
    h.eq(ran, false)
    h.ok(tasks.wait(2000))
    h.eq(ran, true)
end)

test('each job reports pending, running, then done', function()
    local seen = {}
    ui.on('task', function(job) table.insert(seen, job.id .. ':' .. job.status) end)
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop), h.lua('b', h.noop) } } })
    h.eq(seen, { 'a:pending', 'b:pending', 'a:running', 'a:done', 'b:running', 'b:done' })
end)

test('snapshot keeps enqueue order', function()
    h.run({
        { name = 'z', tasks = { h.lua('one', h.noop), h.lua('two', h.noop) } },
        { name = 'a', tasks = { h.lua('three', h.noop) } },
    })
    local jobs = vim.tbl_map(function(job) return job.plugin .. '/' .. job.id end, tasks.snapshot().jobs)
    h.eq(jobs, { 'z/one', 'z/two', 'a/three' })
end)

test('a failed job skips the rest of its plugin and nothing else', function()
    local summary = h.run({
        {
            name = 'bad',
            tasks = {
                h.lua('x', function() error('boom') end),
                h.lua('y', h.noop),
            },
        },
        { name = 'good', tasks = { h.lua('z', h.noop) } },
    })
    h.eq(h.job('bad', 'x').status, 'failed')
    h.ok(h.job('bad', 'x').error:find('boom', 1, true))
    h.eq(h.job('bad', 'y').status, 'skipped')
    h.eq(h.job('good', 'z').status, 'done')
    h.eq(summary, { total = 3, done = 1, failed = 1, skipped = 1 })
end)

test('dependents wait for their dependencies, whatever the enqueue order', function()
    local order = {}
    local function mark(name)
        return function() table.insert(order, name) end
    end
    h.run({
        { name = 'app', deps = { 'lib' }, tasks = { h.lua('a', mark('app')) } },
        { name = 'lib', tasks = { h.lua('l', mark('lib')) } },
    })
    h.eq(order, { 'lib', 'app' })
end)

test('a failed dependency skips its dependents', function()
    h.run({
        { name = 'app', deps = { 'lib' }, tasks = { h.lua('a', h.noop) } },
        {
            name = 'lib',
            tasks = {
                h.lua('l', function() error('no') end),
            },
        },
    })
    h.eq(h.job('app', 'a').status, 'skipped')
    h.eq(h.job('app', 'a').note, 'dependency lib failed')
end)

test('retries a failing job', function()
    local calls = 0
    h.run({
        {
            name = 'p',
            tasks = {
                h.lua('flaky', function()
                    calls = calls + 1
                    if calls < 3 then error('nope') end
                end, { retries = 2 }),
            },
        },
    })
    h.eq(calls, 3)
    h.eq(h.job('p', 'flaky').status, 'done')
    h.eq(h.job('p', 'flaky').attempts, 3)
end)

test('gives up once retries run out', function()
    h.run({
        {
            name = 'p',
            tasks = {
                h.lua('always', function() error('nope') end, { retries = 1 }),
            },
        },
    })
    h.eq(h.job('p', 'always').status, 'failed')
    h.eq(h.job('p', 'always').attempts, 2)
end)

test('an unknown task type fails visibly', function()
    h.run({ { name = 'p', tasks = { { id = 'x', type = 'nope' } } } })
    h.eq(h.job('p', 'x').status, 'failed')
    h.ok(h.job('p', 'x').error:find('unknown task type nope', 1, true))
end)

test('drops tasks whose `when` is false or invalid', function()
    tasks.enqueue('p', {
        tasks = {
            h.lua('no', h.noop, { when = 'false' }),
            h.lua('yes', h.noop, { when = '1 == 1' }),
            h.lua('bad', h.noop, { when = '((' }),
        },
    })
    h.eq(h.ids(tasks.snapshot().jobs), { 'yes' })
    tasks.run_all()
    tasks.wait(2000)
end)

test('ignores a second done and survives a throwing executor', function()
    h.run({ { name = 'p', tasks = { { id = 'a', type = 't_twice' } } } })
    h.eq(h.job('p', 'a').status, 'done')
    h.run({ { name = 'q', tasks = { { id = 'b', type = 't_throws' } } } })
    h.eq(h.job('q', 'b').status, 'failed')
    h.ok(h.job('q', 'b').error:find('kaput', 1, true))
end)

test('never runs more plugins at once than max_concurrent', function()
    local running, peak = 0, 0
    executors.t_count = function(_, done)
        running = running + 1
        peak = math.max(peak, running)
        vim.defer_fn(function()
            running = running - 1
            done(true)
        end, 20)
    end
    tasks.max_concurrent = 2
    local plugins = {}
    for i = 1, 6 do
        table.insert(plugins, { name = 'p' .. i, tasks = { { id = 's', type = 't_count' } } })
    end
    h.run(plugins)
    h.eq(peak, 2)
end)

-- Install jobs that last `ms`, tracking how many run at once and when each ends.
local function install_tracker(log)
    local state = { running = 0, peak = 0 }
    executors.t_install = function(job, done)
        state.running = state.running + 1
        state.peak = math.max(state.peak, state.running)
        vim.defer_fn(function()
            state.running = state.running - 1
            table.insert(log, 'installed:' .. job.plugin)
            if job.spec.fail then return done(false, 'no network') end
            done(true)
        end, job.spec.ms or 30)
    end
    return state
end

local function install(extra)
    return vim.tbl_extend('force', { id = 'install', type = 't_install', phase = 'install' }, extra or {})
end

test('installs run together, beyond max_concurrent, up to max_installs', function()
    local state = install_tracker({})
    tasks.max_concurrent = 2
    tasks.max_installs = 5
    local plugins = {}
    for i = 1, 8 do
        table.insert(plugins, { name = 'p' .. i, tasks = { install() } })
    end
    h.run(plugins)
    h.eq(state.peak, 5)
end)

test('installs do not wait for the plugins they depend on', function()
    local state = install_tracker({})
    h.run({
        { name = 'app', deps = { 'lib' }, tasks = { install() } },
        { name = 'lib', tasks = { install() } },
    })
    h.eq(state.peak, 2)
end)

test('no other task starts until every install has finished', function()
    local log = {}
    install_tracker(log)
    h.run({
        {
            name = 'fast',
            tasks = {
                install({ ms = 5 }),
                h.lua('after_install', function() table.insert(log, 'ran:fast') end),
            },
        },
        {
            name = 'slow',
            tasks = {
                install({ ms = 80 }),
                h.lua('after_install', function() table.insert(log, 'ran:slow') end),
            },
        },
    })
    h.eq(log, { 'installed:fast', 'installed:slow', 'ran:fast', 'ran:slow' })
end)

test('after the installs, dependencies still run before their dependents', function()
    local log = {}
    install_tracker(log)
    h.run({
        {
            name = 'app',
            deps = { 'lib' },
            tasks = { install(), h.lua('go', function() table.insert(log, 'go:app') end) },
        },
        { name = 'lib', tasks = { install(), h.lua('go', function() table.insert(log, 'go:lib') end) } },
    })
    h.eq(vim.list_slice(log, 3), { 'go:lib', 'go:app' })
end)

test('a failed install skips only that plugin, and the others still run', function()
    local log = {}
    install_tracker(log)
    local summary = h.run({
        {
            name = 'bad',
            tasks = { install({ fail = true }), h.lua('go', function() table.insert(log, 'go:bad') end) },
        },
        { name = 'good', tasks = { install(), h.lua('go', function() table.insert(log, 'go:good') end) } },
    })
    h.eq(h.job('bad', 'install').status, 'failed')
    h.eq(h.job('bad', 'go').status, 'skipped')
    h.eq(vim.tbl_contains(log, 'go:good'), true)
    h.eq(vim.tbl_contains(log, 'go:bad'), false)
    h.eq(summary.failed, 1)
end)

test('a plugin whose dependency failed to install is skipped after the installs', function()
    install_tracker({})
    h.run({
        { name = 'lib', tasks = { install({ fail = true }) } },
        { name = 'app', deps = { 'lib' }, tasks = { install(), h.lua('go', h.noop) } },
    })
    h.eq(h.job('app', 'install').status, 'done')
    h.eq(h.job('app', 'go').status, 'skipped')
    h.eq(h.job('app', 'go').note, 'dependency lib failed')
end)

test('run_inline runs the tasks before returning and records them as done', function()
    local log = {}
    local ok = tasks.run_inline('p', {
        tasks = {
            h.lua('a', function() table.insert(log, 'a') end),
            h.lua('b', function() table.insert(log, 'b') end),
        },
    })
    h.eq(ok, true)
    h.eq(log, { 'a', 'b' })
    h.eq({ h.job('p', 'a').status, h.job('p', 'b').status }, { 'done', 'done' })
    h.eq(tasks.has_active(), false)
end)

test('run_inline waits for an executor that answers later', function()
    h.eq(tasks.run_inline('p', { tasks = { { id = 'slow', type = 't_sleep' } } }), true)
    h.eq(h.job('p', 'slow').status, 'done')
end)

test('a failing inline task skips the rest, fails the plugin and skips what is queued later', function()
    local ran = false
    local ok = tasks.run_inline('p', {
        tasks = {
            h.lua('bad', function() error('inline broke') end),
            h.lua('next', function() ran = true end),
        },
    })
    h.eq(ok, false)
    h.eq(ran, false)
    h.ok(h.job('p', 'bad').error:find('inline broke', 1, true))
    h.eq(h.job('p', 'next').status, 'skipped')
    h.eq(tasks.plugin_failed('p'), true)
    tasks.enqueue('p', { tasks = { h.lua('queued', function() ran = true end) } }, { append = true })
    tasks.run_all(nil, { append = true })
    h.ok(tasks.wait(2000))
    h.eq(ran, false)
    h.eq(h.job('p', 'queued').status, 'skipped')
end)

test('a plugin that ran inline counts as finished for its dependents', function()
    local log = {}
    tasks.run_inline('lib', { tasks = { h.lua('x', function() table.insert(log, 'lib') end) } })
    tasks.enqueue(
        'app',
        { deps = { 'lib' }, tasks = { h.lua('y', function() table.insert(log, 'app') end) } },
        { append = true }
    )
    tasks.run_all(nil, { append = true })
    h.ok(tasks.wait(2000))
    h.eq(log, { 'lib', 'app' })
end)

test('wait starts a run that is queued but not started', function()
    local ran = false
    tasks.enqueue('p', { tasks = { h.lua('a', function() ran = true end) } })
    h.ok(tasks.wait(2000))
    h.eq(ran, true)
end)

test('runs different plugins in parallel', function()
    local running, peak = 0, 0
    executors.t_par = function(_, done)
        running = running + 1
        peak = math.max(peak, running)
        vim.defer_fn(function()
            running = running - 1
            done(true)
        end, 30)
    end
    h.run({
        { name = 'a', tasks = { { id = 's', type = 't_par' } } },
        { name = 'b', tasks = { { id = 's', type = 't_par' } } },
    })
    h.eq(peak, 2)
end)

test('calls back with a summary, even for an empty queue', function()
    local got
    tasks.run_all(function(summary) got = summary end)
    h.ok(vim.wait(1000, function() return got ~= nil end))
    h.eq(got, { total = 0, done = 0, failed = 0, skipped = 0 })
end)

test('an appended run keeps earlier jobs and reports only its own', function()
    h.run({
        {
            name = 'a',
            tasks = {
                h.lua('x', function() error('no') end),
                h.lua('y', h.noop),
            },
        },
    })
    tasks.enqueue('b', { tasks = { h.lua('z', h.noop) } }, { append = true })
    local summary
    tasks.run_all(function(s) summary = s end, { append = true })
    h.ok(tasks.wait(2000))
    h.eq(summary, { total = 1, done = 1, failed = 0, skipped = 0 })
    h.eq(h.ids(tasks.snapshot().jobs), { 'x', 'y', 'z' })
    h.eq(tasks.snapshot().counts.failed, 1)
end)

test('the start event says whether a run is fresh', function()
    local starts = {}
    ui.on('start', function(info) table.insert(starts, info.fresh) end)
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop) } } })
    tasks.enqueue('q', { tasks = { h.lua('b', h.noop) } }, { append = true })
    tasks.run_all(nil, { append = true })
    h.ok(tasks.wait(2000))
    h.eq(starts, { true, false })
end)

test('a second run starts from a clean slate', function()
    h.run({ { name = 'p', tasks = { h.lua('old', h.noop) } } })
    h.run({ { name = 'p', tasks = { h.lua('new', h.noop) } } })
    h.eq(h.ids(tasks.snapshot().jobs), { 'new' })
end)

return tests
