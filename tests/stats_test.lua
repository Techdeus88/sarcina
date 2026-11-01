local h = require('helpers')
local executors = require('sarcina.executors')
local load = require('sarcina.load')
local paths = require('sarcina.paths')
local resolver = require('sarcina.resolver')
local scheduler = require('sarcina.scheduler')
local startup = require('sarcina.startup')
local stats = require('sarcina.stats')
local tasks = require('sarcina.tasks')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- A plugin on disk whose module has a setup(), found from the plugin name.
local function installed(name, module)
    h.plugin_dir({ [module] = 'local M = {}\nfunction M.setup() end\nreturn M' }, paths.install(name))
end

local function begin(specs)
    local resolved = resolver.resolve(specs)
    stats.register(resolved)
    startup.start(resolved)
end

test('plugins are counted by timing, dependencies included, and the counts add up', function()
    stats.register(resolver.resolve({
        { name = 'app', repo = 'x/app', load = 'now', deps = { 'lib' } },
        { name = 'lib', repo = 'x/lib', cmd = 'Lib' },
        { name = 'page', repo = 'x/page', deps = { 'tool' } },
        { name = 'tool', repo = 'x/tool', ft = 'lua' },
        { name = 'lone', repo = 'x/lone', cmd = 'Lone' },
    }))
    local numbers = stats.get()
    h.eq({ numbers.count, numbers.now, numbers.later, numbers.triggered }, { 5, 2, 2, 1 })
    h.eq(numbers.now + numbers.later + numbers.triggered, numbers.count)
    h.eq({ numbers.loaded, numbers.not_loaded }, { 0, 5 })
end)

test(
    'a now plugin is loaded at once, a later one after the wait, a triggered one only after its trigger',
    function()
        installed('stsnow.nvim', 'stsnow')
        installed('stslater.nvim', 'stslater')
        installed('ststrig.nvim', 'ststrig')
        begin({
            { name = 'stsnow.nvim', repo = 'x/stsnow', load = 'now', opts = {} },
            { name = 'stslater.nvim', repo = 'x/stslater', opts = {} },
            { name = 'ststrig.nvim', repo = 'x/ststrig', cmd = 'StatsTrigCmd', opts = {} },
        })
        h.eq({ stats.get().loaded, stats.get().not_loaded }, { 1, 2 })
        h.ok(tasks.wait(2000))
        h.eq({ stats.get().loaded, stats.get().not_loaded }, { 2, 1 })
        scheduler.load('ststrig.nvim')
        h.ok(vim.wait(2000, function() return scheduler.state('ststrig.nvim') == 'loaded' end))
        h.ok(tasks.wait(2000))
        h.eq({ stats.get().loaded, stats.get().not_loaded }, { 3, 0 })
    end
)

test('a plugin whose load fails, and its dependent, are not loaded', function()
    installed('stsbad.nvim', 'stsbad')
    installed('stsdep.nvim', 'stsdep')
    begin({
        { name = 'stsbad.nvim', repo = 'x/stsbad', load = 'now', config = function() error('nope') end },
        { name = 'stsdep.nvim', repo = 'x/stsdep', deps = { 'stsbad.nvim' }, opts = {} },
    })
    h.ok(tasks.wait(2000))
    h.eq({ stats.get().loaded, stats.get().not_loaded }, { 0, 2 })
end)

test('User SarcinaReady fires once the startup run is done, with the final stats', function()
    installed('stsrnow.nvim', 'stsrnow')
    installed('stsrlater.nvim', 'stsrlater')
    local got, count = nil, 0
    local group = vim.api.nvim_create_augroup('stats_ready_test', { clear = true })
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'SarcinaReady',
        callback = function(args)
            got, count = args.data, count + 1
        end,
    })
    begin({
        { name = 'stsrnow.nvim', repo = 'x/stsrnow', load = 'now', opts = {} },
        { name = 'stsrlater.nvim', repo = 'x/stsrlater', opts = {} },
    })
    h.eq(got, nil)
    h.ok(vim.wait(2000, function() return got ~= nil end, 5), 'SarcinaReady never fired')
    vim.wait(100)
    vim.api.nvim_del_augroup_by_name('stats_ready_test')
    h.eq({ got.count, got.loaded, got.not_loaded, count }, { 2, 2, 0, 1 })
    h.eq(type(got.startup_ms), 'number')
end)

test('startup_ms is absent before the UI is up and a number after', function()
    load._reset(false)
    stats.begin()
    h.eq(stats.get().startup_ms, nil)
    load._open()
    h.ok(vim.wait(1000, load.idle, 5), 'the load gate did not settle')
    local ms = stats.get().startup_ms
    h.eq(type(ms), 'number')
    h.ok(ms >= 0)
end)

test('startup_ms never goes below zero when setup runs after the UI is up', function()
    load._reset(true)
    vim.wait(5)
    stats.begin()
    h.eq(stats.get().startup_ms, 0)
end)

test('the public function is the stats getter and the table has exactly the documented keys', function()
    h.eq(require('sarcina').stats, stats.get)
    local keys = vim.tbl_keys(stats.get())
    table.sort(keys)
    h.eq(keys, { 'count', 'later', 'loaded', 'not_loaded', 'now', 'startup_ms', 'triggered' })
end)

test('get lists every plugin with its complete spec, in the resolver order, dependencies first', function()
    local config = function() end
    stats.register(resolver.resolve({
        { name = 'app', repo = 'x/app', load = 'now', deps = { 'x/lib' }, config = config },
        { name = 'page', repo = 'x/page', cmd = 'GetPage' },
    }))
    local all = require('sarcina').get()
    h.eq(h.names(all), { 'lib', 'app', 'page' })
    h.eq(vim.tbl_map(function(entry) return entry.timing end, all), { 'now', 'now', 'trigger' })
    local app = all[2].spec
    h.eq({ app.repo, app.deps }, { 'x/app', { 'lib' } })
    h.eq(h.ids(app.tasks), { 'install', 'rtp', 'load' })
    h.eq(app.tasks[3].fn, config)
    h.eq(all[3].spec.triggers, { cmd = { 'GetPage' } })
    h.eq(all[1].spec.repo, 'x/lib')
end)

test('get(name) returns one plugin, or nil for a name it does not know', function()
    stats.register(resolver.resolve({ { name = 'one', repo = 'x/one' }, { name = 'two', repo = 'x/two' } }))
    local one = require('sarcina').get('one')
    h.eq({ one.name, one.timing, one.spec.repo }, { 'one', 'later', 'x/one' })
    h.eq(require('sarcina').get('three'), nil)
end)

test('get hands out copies, so changing one never changes what the engine runs', function()
    stats.register(resolver.resolve({ { name = 'one', repo = 'x/one' } }))
    local copy = require('sarcina').get('one')
    copy.spec.repo = 'changed'
    table.insert(copy.spec.tasks, { id = 'extra' })
    local again = require('sarcina').get('one')
    h.eq({ again.spec.repo, #again.spec.tasks }, { 'x/one', 2 })
end)

test('get is empty before setup has registered anything', function()
    h.eq(require('sarcina').get(), {})
    h.eq(require('sarcina').get('one'), nil)
end)

test('stats.tasks lists every task with times since setup began', function()
    stats.begin()
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop), h.lua('b', h.noop) } } })
    local records = stats.tasks()
    h.eq({ #records, records[1].id, records[2].id }, { 2, 'a', 'b' })
    h.ok(records[1].started >= 0 and records[1].ended <= records[2].ended)
end)

-- A task that stays running until `releases[plugin]()`. `s_hold` does real work, `s_idle` does none.
local releases = {}
executors.s_hold = function(job, done, report)
    job.working = true
    report('cloning')
    releases[job.plugin] = function() done(true) end
end
executors.s_idle = function(job, done)
    releases[job.plugin] = function() done(true) end
end

test('stats.plugins lists the registered plugins in load order, dependencies first', function()
    stats.register(resolver.resolve({
        { name = 'stoa', repo = 'x/stoa', deps = { 'stob' } },
        { name = 'stob', repo = 'x/stob' },
    }))
    h.eq(h.names(stats.plugins()), { 'stob', 'stoa' })
    local row = stats.plugin('stoa')
    h.eq({ row.state, row.task, row.tasks, row.timing }, { 'pending', 0, 2, 'later' })
    h.eq(stats.plugin('stonone'), nil)
end)

test('the rows follow the order the plugins really load: now, then later, then the trigger', function()
    for _, name in ipairs({ 'stolater', 'stotrig', 'stonow' }) do
        installed(name .. '.nvim', name)
    end
    begin({
        { name = 'stolater.nvim', repo = 'x/stolater', opts = {} },
        { name = 'stotrig.nvim', repo = 'x/stotrig', cmd = 'StatsOrderCmd', opts = {} },
        { name = 'stonow.nvim', repo = 'x/stonow', load = 'now', opts = {} },
    })
    h.eq(h.names(stats.plugins()), { 'stonow.nvim', 'stolater.nvim', 'stotrig.nvim' })
    h.ok(tasks.wait(2000))
    h.eq(h.names(stats.plugins()), { 'stonow.nvim', 'stolater.nvim', 'stotrig.nvim' })
    scheduler.load('stotrig.nvim')
    h.ok(vim.wait(2000, function() return scheduler.state('stotrig.nvim') == 'loaded' end))
    h.ok(tasks.wait(2000))
    h.eq(h.names(stats.plugins()), { 'stonow.nvim', 'stolater.nvim', 'stotrig.nvim' })
end)

test('a plugin takes its row where it loaded, not where the manifest lists it', function()
    installed('stfirst.nvim', 'stfirst')
    installed('stsecond.nvim', 'stsecond')
    local first = {
        name = 'stfirst.nvim',
        tasks = { { id = 'wait', type = 's_idle' }, { id = 'rtp', type = 'rtp' } },
    }
    local second = { name = 'stsecond.nvim', tasks = { { id = 'rtp', type = 'rtp' } } }
    h.register({ first, second })
    h.eq(h.names(stats.plugins()), { 'stfirst.nvim', 'stsecond.nvim' })
    tasks.enqueue('stfirst.nvim', first)
    tasks.enqueue('stsecond.nvim', second)
    tasks.run_all()
    h.ok(vim.wait(500, function() return stats.plugin('stsecond.nvim').state == 'loaded' end))
    h.eq(h.names(stats.plugins()), { 'stsecond.nvim', 'stfirst.nvim' })
    releases['stfirst.nvim']()
    h.ok(tasks.wait(2000))
    h.eq(h.names(stats.plugins()), { 'stsecond.nvim', 'stfirst.nvim' })
end)

test('an installed later plugin goes from pending to loaded, its install counted as done', function()
    installed('stplater.nvim', 'stplater')
    begin({ { name = 'stplater.nvim', repo = 'x/stplater', opts = {} } })
    local row = stats.plugin('stplater.nvim')
    h.eq({ row.state, row.task, row.tasks, row.timing }, { 'pending', 1, 3, 'later' })
    h.ok(tasks.wait(2000))
    row = stats.plugin('stplater.nvim')
    h.eq({ row.state, row.task, row.tasks }, { 'loaded', 3, 3 })
end)

test('a triggered plugin waits at its trigger task, and its whole plan counts once it loads', function()
    installed('sttrig.nvim', 'sttrig')
    begin({ { name = 'sttrig.nvim', repo = 'x/sttrig', cmd = 'StatsPlanCmd', opts = {} } })
    local row = stats.plugin('sttrig.nvim')
    h.eq({ row.state, row.task, row.tasks, row.timing }, { 'waiting', 2, 4, 'trigger' })
    h.eq(row.detail, 'waiting for :StatsPlanCmd')
    scheduler.load('sttrig.nvim')
    h.ok(vim.wait(2000, function() return scheduler.state('sttrig.nvim') == 'loaded' end))
    h.ok(tasks.wait(2000))
    row = stats.plugin('sttrig.nvim')
    h.eq({ row.state, row.task, row.tasks }, { 'loaded', 4, 4 })
end)

test('an install shows as work only once it does real work, and says what it is doing', function()
    local idle = { name = 'stidle', tasks = { { id = 'install', type = 's_idle' }, h.lua('rtp', h.noop) } }
    local busy = { name = 'stbusy', tasks = { { id = 'install', type = 's_hold' }, h.lua('rtp', h.noop) } }
    h.register({ idle, busy })
    tasks.enqueue('stidle', idle)
    tasks.enqueue('stbusy', busy)
    tasks.run_all()
    h.ok(vim.wait(500, function() return stats.plugin('stbusy').state == 'installing' end))
    local row = stats.plugin('stbusy')
    h.eq({ row.task, row.tasks, row.detail }, { 1, 2, 'cloning' })
    h.eq(stats.plugin('stidle').state, 'pending')
    releases.stidle()
    releases.stbusy()
    h.ok(tasks.wait(2000))
    h.eq({ stats.plugin('stidle').state, stats.plugin('stbusy').state }, { 'loaded', 'loaded' })
end)

test('a build that does real work shows as building', function()
    local plugin = { name = 'stbuild', tasks = { { id = 'build', type = 's_hold' }, h.lua('rtp', h.noop) } }
    h.register({ plugin })
    tasks.enqueue('stbuild', plugin)
    tasks.run_all()
    h.ok(vim.wait(500, function() return stats.plugin('stbuild').state == 'building' end))
    releases.stbuild()
    h.ok(tasks.wait(2000))
    h.eq(stats.plugin('stbuild').state, 'loaded')
end)

test('a failed task fails its row with the error, and a dependent of it is blocked', function()
    local bad = {
        name = 'stbad',
        tasks = { h.lua('rtp', h.noop), h.lua('load', function() error('boom') end), h.lua('after', h.noop) },
    }
    local dependent = { name = 'stdependent', deps = { 'stbad' }, tasks = { h.lua('rtp', h.noop) } }
    h.register({ bad, dependent })
    h.run({ bad, dependent })
    local row = stats.plugin('stbad')
    h.eq({ row.state, row.task, row.tasks, row.detail }, { 'failed', 2, 3, 'boom' })
    row = stats.plugin('stdependent')
    h.eq({ row.state, row.task, row.tasks, row.detail }, { 'blocked', 0, 1, 'dependency stbad failed' })
end)

local function step_list(name)
    return vim.tbl_map(function(step) return step.id .. ':' .. step.status end, stats.steps(name))
end

test('stats.spec returns the live resolved entry of a plugin, or nil', function()
    stats.register(resolver.resolve({ { name = 'stspec', repo = 'x/stspec' } }))
    local entry = stats.spec('stspec')
    h.eq({ entry.name, entry.timing, entry.spec.repo }, { 'stspec', 'later', 'x/stspec' })
    h.eq(stats.spec('stnone'), nil)
end)

test(
    'steps list a fresh plan as pending, and an installed plugin counts its install as not needed',
    function()
        stats.register(resolver.resolve({ { name = 'stfresh.nvim', repo = 'x/stfresh', opts = {} } }))
        h.eq(step_list('stfresh.nvim'), { 'install:pending', 'rtp:pending', 'load:pending' })
        h.eq(stats.steps('stnone'), nil)
        installed('stinst.nvim', 'stinst')
        begin({ { name = 'stinst.nvim', repo = 'x/stinst', opts = {} } })
        local steps = stats.steps('stinst.nvim')
        h.eq({ steps[1].status, steps[1].note }, { 'done', 'not needed' })
        h.eq({ steps[2].status, steps[3].status }, { 'pending', 'pending' })
        h.ok(tasks.wait(2000))
        steps = stats.steps('stinst.nvim')
        h.eq(step_list('stinst.nvim'), { 'install:done', 'rtp:done', 'load:done' })
        h.ok(steps[2].duration ~= nil and steps[3].duration ~= nil, 'a task that ran has a duration')
    end
)

test('steps of a waiting triggered plugin have the trigger done and the deferred tasks pending', function()
    installed('stwait.nvim', 'stwait')
    begin({ { name = 'stwait.nvim', repo = 'x/stwait', cmd = 'StatsStepsCmd', opts = {} } })
    h.eq(step_list('stwait.nvim'), { 'install:done', 'load_trigger:done', 'rtp:pending', 'load:pending' })
    h.eq(stats.steps('stwait.nvim')[2].note, 'waiting for :StatsStepsCmd')
end)

test('steps show a failed task with its error line and the tasks skipped after it', function()
    local bad = {
        name = 'stfailsteps',
        tasks = { h.lua('rtp', h.noop), h.lua('load', function() error('boom') end), h.lua('after', h.noop) },
    }
    h.register({ bad })
    h.run({ bad })
    local steps = stats.steps('stfailsteps')
    h.eq(step_list('stfailsteps'), { 'rtp:done', 'load:failed', 'after:skipped' })
    h.eq({ steps[2].error, steps[3].note }, { 'boom', 'load failed' })
end)

test('steps show the output of a running task', function()
    local plugin = { name = 'stoutput', tasks = { { id = 'install', type = 's_hold' } } }
    h.register({ plugin })
    tasks.enqueue('stoutput', plugin)
    tasks.run_all()
    h.ok(vim.wait(500, function() return stats.steps('stoutput')[1].output == 'cloning' end))
    h.eq(stats.steps('stoutput')[1].status, 'running')
    releases.stoutput()
    h.ok(tasks.wait(2000))
end)

-- Runs a real startup in a child Neovim and prints the stats once the startup run is done.
local function run_child()
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({
        string.format('vim.opt.rtp:prepend(%q)', root),
        "require('sarcina').setup()",
        "vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()",
        '    vim.defer_fn(function()',
        "        require('sarcina.tasks').wait(5000)",
        "        vim.cmd('StatsChildCmd')",
        "        vim.wait(3000, function() return require('sarcina.scheduler').state('stctrig.nvim') == 'loaded' end)",
        "        require('sarcina.tasks').wait(5000)",
        "        io.stdout:write(vim.json.encode(require('sarcina').stats()))",
        '        vim.cmd.qa({ bang = true })',
        '    end, 100)',
        'end })',
    }, script)
    local res = vim.system({ vim.v.progpath, '--headless', '-i', 'NONE', '-u', script }, { text = true })
        :wait(15000)
    h.eq(res.code, 0, res.stderr)
    return vim.json.decode(res.stdout)
end

test(
    'in a real startup the numbers cover now, later and triggered plugins, and a command loads its plugin',
    function()
        for _, name in ipairs({ 'stcnow.nvim', 'stclater.nvim', 'stctrig.nvim' }) do
            vim.fn.mkdir(paths.install(name), 'p')
        end
        vim.fn.mkdir(paths.install('stctrig.nvim') .. '/plugin', 'p')
        vim.fn.writefile({
            "vim.api.nvim_create_user_command('StatsChildCmd', function() vim.g.stats_child_cmd = true end, {})",
        }, paths.install('stctrig.nvim') .. '/plugin/stctrig.lua')
        local specs = vim.fn.stdpath('config') .. '/lua/plugins'
        vim.fn.mkdir(specs, 'p')
        local file = specs .. '/stats_child.lua'
        vim.fn.writefile({
            'return {',
            "    { name = 'stcnow.nvim', repo = 'x/stcnow', load = 'now', config = function() end },",
            "    { name = 'stclater.nvim', repo = 'x/stclater', config = function() end },",
            "    { name = 'stctrig.nvim', repo = 'x/stctrig', cmd = 'StatsChildCmd', config = function() end },",
            '}',
        }, file)
        local numbers = run_child()
        vim.fn.delete(file)
        h.eq(vim.tbl_extend('force', numbers, { startup_ms = 'set' }), {
            count = 3,
            loaded = 3,
            not_loaded = 0,
            now = 1,
            later = 1,
            triggered = 1,
            startup_ms = 'set',
        })
        h.eq(type(numbers.startup_ms), 'number')
    end
)

-- A dashboard reads the stats when the UI appears, and again when the startup run says it is done.
local function run_ready_child()
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({
        string.format('vim.opt.rtp:prepend(%q)', root),
        "vim.api.nvim_create_autocmd('User', { pattern = 'SarcinaReady', once = true, callback = function(args)",
        '    _G.ready = args.data',
        'end })',
        "vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()",
        "    vim.schedule(function() _G.early = require('sarcina').stats() end)",
        'end })',
        "require('sarcina').setup()",
        "vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()",
        '    vim.defer_fn(function()',
        '        vim.wait(5000, function() return _G.ready ~= nil end)',
        '        io.stdout:write(vim.json.encode({ ready = _G.ready, early = _G.early }))',
        '        vim.cmd.qa({ bang = true })',
        '    end, 100)',
        'end })',
    }, script)
    local res = vim.system({ vim.v.progpath, '--headless', '-i', 'NONE', '-u', script }, { text = true })
        :wait(15000)
    h.eq(res.code, 0, res.stderr)
    return vim.json.decode(res.stdout)
end

test(
    'in a real startup a reading at the first moment is early, and SarcinaReady brings the final one',
    function()
        for _, name in ipairs({ 'srnow.nvim', 'srlater.nvim', 'srtrig.nvim' }) do
            vim.fn.mkdir(paths.install(name), 'p')
        end
        local specs = vim.fn.stdpath('config') .. '/lua/plugins'
        vim.fn.mkdir(specs, 'p')
        local file = specs .. '/stats_child.lua'
        vim.fn.writefile({
            'return {',
            "    { name = 'srnow.nvim', repo = 'x/srnow', load = 'now', config = function() end },",
            "    { name = 'srlater.nvim', repo = 'x/srlater', config = function() end },",
            "    { name = 'srtrig.nvim', repo = 'x/srtrig', cmd = 'StatsReadyCmd', config = function() end },",
            '}',
        }, file)
        local seen = run_ready_child()
        vim.fn.delete(file)
        h.eq({ seen.ready.count, seen.ready.loaded, seen.ready.not_loaded }, { 3, 2, 1 })
        h.eq(type(seen.ready.startup_ms), 'number')
        h.ok(seen.early.loaded < seen.ready.loaded, 'the early reading already saw the later plugins')
    end
)

return tests
