local h = require('helpers')
local executors = require('sarcina.executors')
local tasks = require('sarcina.tasks')
local track = require('sarcina.track')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

-- Calls `fn` once `ms` have really passed. A bare timer can fire early when libuv's loop time is stale.
local function after(ms, fn)
    local from = vim.uv.hrtime()
    local function poll()
        if (vim.uv.hrtime() - from) / 1e6 >= ms then return fn() end
        vim.defer_fn(poll, 2)
    end
    poll()
end

executors.t_wait = function(_, done)
    after(30, function() done(true) end)
end

local function find(records, plugin, id)
    for _, record in ipairs(records) do
        if record.plugin == plugin and record.id == id then return record end
    end
end

test('a task is stamped created, started and ended, and its duration is the difference', function()
    h.run({ { name = 'p', tasks = { { id = 'a', type = 't_wait' } } } })
    local job = h.job('p', 'a')
    h.ok(job.created <= job.started, 'created after started')
    h.ok(job.started < job.ended, 'ended before started')
    h.ok(job.duration >= 25, 'duration ' .. job.duration)
    h.ok(math.abs(job.duration - (job.ended - job.started) / 1e6) < 0.001)
end)

test('the records carry the same numbers the job holds, in ms since the origin', function()
    local origin = vim.uv.hrtime()
    h.run({ { name = 'p', tasks = { { id = 'a', type = 't_wait', meta = { phase = 'a' } } } } })
    local record = find(track.records(origin), 'p', 'a')
    local job = h.job('p', 'a')
    h.eq(record.duration, job.duration)
    h.eq(record.status, 'done')
    h.eq(record.meta, { phase = 'a' })
    h.ok(record.created >= 0 and record.created <= record.started and record.started < record.ended)
    h.ok(math.abs(record.ended - record.started - record.duration) < 0.001)
end)

test('a retried task keeps its first start and its duration spans both attempts', function()
    local first
    local attempts = 0
    executors.t_flaky = function(job, done)
        attempts = attempts + 1
        first = first or job.started
        after(20, function()
            if attempts == 1 then return done(false, 'once') end
            done(true)
        end)
    end
    h.run({ { name = 'p', tasks = { { id = 'a', type = 't_flaky', retries = 1 } } } })
    local job = h.job('p', 'a')
    h.eq(job.attempts, 2)
    h.eq(job.started, first)
    h.ok(job.duration >= 35, 'duration ' .. job.duration)
    h.eq(#track.history(), 1)
end)

test('a failed task is tracked with its error and timing', function()
    h.run({ { name = 'p', tasks = { h.lua('bad', function() error('boom') end) } } })
    local record = find(track.records(vim.uv.hrtime() - 1e9), 'p', 'bad')
    h.eq(record.status, 'failed')
    h.ok(record.error:find('boom', 1, true))
    h.ok(record.duration ~= nil and record.ended ~= nil)
end)

test('a skipped task has only its creation', function()
    h.run({
        {
            name = 'p',
            tasks = { h.lua('bad', function() error('boom') end), h.lua('next', h.noop) },
        },
    })
    local record = find(track.records(vim.uv.hrtime() - 1e9), 'p', 'next')
    h.eq(record.status, 'skipped')
    h.ok(record.created ~= nil)
    h.eq({ record.started, record.ended, record.duration, record.waited }, {})
end)

test('a task held behind the install barrier records how long it waited', function()
    executors.t_slow_install = function(_, done)
        after(60, function() done(true) end)
    end
    h.run({
        { name = 'a', tasks = { { id = 'install', type = 't_slow_install', phase = 'install' } } },
        { name = 'b', tasks = { h.lua('go', h.noop) } },
    })
    local record = find(track.records(vim.uv.hrtime() - 1e9), 'b', 'go')
    h.ok(record.waited >= 40, 'waited ' .. record.waited)
end)

test('the history survives a fresh run, which replaces the job list', function()
    h.run({ { name = 'one', tasks = { h.lua('a', h.noop) } } })
    h.run({ { name = 'two', tasks = { h.lua('b', h.noop) } } })
    h.eq(#tasks.snapshot().jobs, 1)
    h.eq(#track.history(), 2)
end)

test('the jobs of one plugin come back in creation order, and an unknown plugin has none', function()
    h.run({
        { name = 'one', tasks = { h.lua('a', h.noop), h.lua('b', h.noop) } },
        { name = 'two', tasks = { h.lua('c', h.noop) } },
    })
    h.eq(h.ids(track.jobs_of('one')), { 'a', 'b' })
    h.eq(h.ids(track.jobs_of('two')), { 'c' })
    h.eq(track.jobs_of('none'), {})
end)

test('a duration is the work of the task, not the time the loop spent on the tasks beside it', function()
    local function busy(ms)
        local from = vim.uv.hrtime()
        while (vim.uv.hrtime() - from) / 1e6 < ms do
        end
    end
    local plugins = {}
    for i = 1, 4 do
        table.insert(plugins, { name = 'busy' .. i, tasks = { h.lua('load', function() busy(40) end) } })
    end
    h.run(plugins)
    for i = 1, 4 do
        local duration = h.job('busy' .. i, 'load').duration
        h.ok(duration >= 39 and duration < 100, 'busy' .. i .. ' took ' .. duration .. ' ms of its own 40')
    end
end)

test('the finished jobs come back in the order they ended, not the order they were created', function()
    executors.t_late = function(_, done)
        vim.defer_fn(function() done(true) end, 40)
    end
    h.run({
        { name = 'slow', tasks = { { id = 'a', type = 't_late' } } },
        { name = 'fast', tasks = { h.lua('b', h.noop) } },
    })
    h.eq(h.ids(track.history()), { 'a', 'b' })
    h.eq(h.ids(track.finished_jobs()), { 'b', 'a' })
end)

test('tasks that run inline are tracked too', function()
    tasks.run_inline('p', { tasks = { h.lua('a', h.noop) } })
    local record = find(track.records(vim.uv.hrtime() - 1e9), 'p', 'a')
    h.eq(record.status, 'done')
    h.ok(record.started ~= nil and record.ended ~= nil and record.duration ~= nil)
end)

return tests
