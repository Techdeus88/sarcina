local h = require('helpers')
local paths = require('sarcina.paths')
local resolver = require('sarcina.resolver')
local scheduler = require('sarcina.scheduler')
local startup = require('sarcina.startup')
local tasks = require('sarcina.tasks')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function log(text) table.insert(_G.start_log, text) end

-- A plugin on disk whose module logs its setup(), found from the plugin name.
local function installed(name, module)
    local body = table.concat({
        'local M = {}',
        'function M.setup() table.insert(_G.start_log, "setup:' .. name .. '") end',
        'return M',
    }, '\n')
    h.plugin_dir({ [module] = body }, paths.install(name))
end

local function init_log(name)
    return function() log('init:' .. name) end
end

local function begin(specs)
    _G.start_log = {}
    startup.start(resolver.resolve(specs))
end

test('an installed now plugin loads before start returns and a later one waits', function()
    installed('stnowp.nvim', 'stnowp')
    installed('stlaterp.nvim', 'stlaterp')
    begin({
        { name = 'stnowp.nvim', repo = 'x/stnowp', load = 'now', opts = {}, init = init_log('stnowp') },
        { name = 'stlaterp.nvim', repo = 'x/stlaterp', opts = {}, init = init_log('stlaterp') },
    })
    h.eq(_G.start_log, { 'init:stnowp', 'setup:stnowp.nvim', 'init:stlaterp' })
    h.ok(tasks.wait(2000))
    h.eq(_G.start_log, { 'init:stnowp', 'setup:stnowp.nvim', 'init:stlaterp', 'setup:stlaterp.nvim' })
end)

test('now plugins load in the order received, dependencies first', function()
    installed('stapp.nvim', 'stapp')
    installed('stlib.nvim', 'stlib')
    begin({
        { name = 'stapp.nvim', repo = 'x/stapp', load = 'now', opts = {}, deps = { 'stlib.nvim' } },
        { name = 'stlib.nvim', repo = 'x/stlib', opts = {} },
    })
    h.eq(_G.start_log, { 'setup:stlib.nvim', 'setup:stapp.nvim' })
end)

test('a now plugin whose dependency is not installed yet loads after the dependency', function()
    installed('storphan.nvim', 'storphan')
    local dep = {
        name = 'stmissing.nvim',
        tasks = { h.lua('make', function() installed('stmissing.nvim', 'stmissing') end) },
    }
    begin({
        { name = 'storphan.nvim', repo = 'x/storphan', load = 'now', opts = {}, deps = { 'stmissing.nvim' } },
        dep,
    })
    h.eq(_G.start_log, {})
    h.ok(tasks.wait(2000))
    h.eq(_G.start_log, { 'setup:storphan.nvim' })
end)

if vim.fn.executable('git') == 1 then
    test('on a first install the now plugins load first, though the manifest lists them last', function()
        begin({
            { name = 'stfreshlater.nvim', repo = h.make_repo(), config = function() log('load:later') end },
            {
                name = 'stfreshnow.nvim',
                repo = h.make_repo(),
                load = 'now',
                config = function() log('load:now') end,
            },
        })
        h.ok(tasks.wait(5000))
        h.eq(_G.start_log, { 'load:now', 'load:later' })
    end)
end

test('a build waits for the UI even for a now plugin', function()
    installed('stbuilt.nvim', 'stbuilt')
    begin({
        {
            name = 'stbuilt.nvim',
            repo = 'x/stbuilt',
            load = 'now',
            opts = {},
            build = function() log('build') end,
        },
    })
    h.eq(_G.start_log, { 'setup:stbuilt.nvim' })
    h.ok(tasks.wait(2000))
    h.eq(_G.start_log, { 'setup:stbuilt.nvim', 'build' })
end)

test('a now plugin whose build is stale loads after the build', function()
    installed('ststale.nvim', 'ststale')
    local dir = paths.install('ststale.nvim')
    vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
    vim.fn.system({ 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '-A' })
    vim.fn.system({ 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'i' })
    begin({
        {
            name = 'ststale.nvim',
            repo = 'x/ststale',
            load = 'now',
            opts = {},
            build = function() log('build') end,
        },
    })
    h.eq(_G.start_log, {})
    h.ok(tasks.wait(2000))
    h.eq(_G.start_log, { 'build', 'setup:ststale.nvim' })
end)

test('a plugin with a trigger runs its init and arms its stub at once, and loads nothing', function()
    installed('sttrig.nvim', 'sttrig')
    begin({
        {
            name = 'sttrig.nvim',
            repo = 'x/sttrig',
            cmd = 'StartTrigCmd',
            opts = {},
            init = init_log('sttrig'),
        },
    })
    h.eq(_G.start_log, { 'init:sttrig' })
    h.eq(vim.fn.exists(':StartTrigCmd'), 2)
    h.eq(scheduler.state('sttrig.nvim'), 'waiting')
    h.ok(tasks.wait(2000))
    h.eq(vim.fn.exists(':StartTrigCmd'), 2)
    h.eq(_G.start_log, { 'init:sttrig' })
end)

test('a now plugin that fails to load fails alone, with one toast and its dependents skipped', function()
    installed('stbadnow.nvim', 'stbadnow')
    installed('stchild.nvim', 'stchild')
    begin({
        {
            name = 'stbadnow.nvim',
            repo = 'x/stbadnow',
            load = 'now',
            config = function() error('bad config') end,
        },
        {
            name = 'stchild.nvim',
            repo = 'x/stchild',
            deps = { 'stbadnow.nvim' },
            config = function() log('child') end,
        },
    })
    h.eq(tasks.plugin_failed('stbadnow.nvim'), true)
    h.ok(tasks.wait(2000))
    h.eq(_G.start_log, {})
    h.eq(h.job('stchild.nvim', 'load').note, 'dependency stbadnow.nvim failed')
    h.ok(h.notified('1 failed'))
end)

if vim.fn.executable('git') == 1 then
    test('a now plugin that is not installed is installed first and then loaded', function()
        local repo = vim.fn.tempname()
        h.plugin_dir({
            stcloned = 'local M = {}\nfunction M.setup() table.insert(_G.start_log, "setup:stcloned.nvim") end\nreturn M',
        }, repo)
        vim.fn.system({ 'git', '-C', repo, 'init', '-q' })
        vim.fn.system({ 'git', '-C', repo, 'add', '-A' })
        vim.fn.system({
            'git',
            '-C',
            repo,
            '-c',
            'user.name=t',
            '-c',
            'user.email=t@t',
            'commit',
            '-q',
            '-m',
            'init',
        })
        begin({ { name = 'stcloned.nvim', repo = repo, load = 'now', opts = {} } })
        h.eq(_G.start_log, {})
        h.eq(vim.uv.fs_stat(paths.install('stcloned.nvim')), nil)
        h.ok(tasks.wait(5000))
        h.eq(_G.start_log, { 'setup:stcloned.nvim' })
    end)
end

-- Runs the real startup in a child Neovim and reports what the plugins saw at VimEnter.
local function run_child()
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({
        string.format('vim.opt.rtp:prepend(%q)', root),
        "require('sarcina').setup()",
        "vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()",
        '    vim.defer_fn(function()',
        "        require('sarcina.tasks').wait(5000)",
        '        io.stdout:write(vim.json.encode({',
        '            early_seen = vim.g.early_seen,',
        '            late_seen = vim.g.late_seen,',
        '            late_config = vim.g.late_config,',
        '        }))',
        '        vim.cmd.qa({ bang = true })',
        '    end, 100)',
        'end })',
    }, script)
    local res = vim.system({ vim.v.progpath, '--headless', '-i', 'NONE', '-u', script }, { text = true })
        :wait(15000)
    h.eq(res.code, 0, res.stderr)
    return vim.json.decode(res.stdout)
end

test('in a real startup a now plugin is configured before VimEnter and a later one is not', function()
    local watch =
        'vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.g.%s_seen = vim.g.%s_config end })'
    for _, name in ipairs({ 'early', 'late' }) do
        local dir = paths.install(name .. '.nvim')
        vim.fn.mkdir(dir .. '/plugin', 'p')
        vim.fn.writefile({ watch:format(name, name) }, dir .. '/plugin/' .. name .. '.lua')
    end
    local specs = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(specs, 'p')
    local file = specs .. '/startup_child.lua'
    vim.fn.writefile({
        'return {',
        "    { name = 'early.nvim', repo = 'x/early', load = 'now', config = function() vim.g.early_config = 'configured' end },",
        "    { name = 'late.nvim', repo = 'x/late', config = function() vim.g.late_config = 'configured' end },",
        '}',
    }, file)
    local seen = run_child()
    vim.fn.delete(file)
    h.eq(seen, { early_seen = 'configured', late_config = 'configured' })
end)

return tests
