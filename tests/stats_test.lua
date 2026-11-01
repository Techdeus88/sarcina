local h = require('helpers')
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

test('stats.tasks lists every task with times since setup began', function()
    stats.begin()
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop), h.lua('b', h.noop) } } })
    local records = stats.tasks()
    h.eq({ #records, records[1].id, records[2].id }, { 2, 'a', 'b' })
    h.ok(records[1].started >= 0 and records[1].ended <= records[2].ended)
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
