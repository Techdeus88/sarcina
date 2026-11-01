local h = require('helpers')
local executors = require('sarcina.executors')
local factory = require('sarcina.task_factory')
local paths = require('sarcina.paths')
local stats = require('sarcina.stats')
local tasks = require('sarcina.tasks')
local ui = require('sarcina.ui')
local window = require('sarcina.window')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- An install that does real work and stays running until `release()`.
local release
executors.w_hold = function(job, done, report)
    job.working = true
    report('Receiving objects: 45%')
    release = function() done(true) end
end

executors.w_slow = function(_, done)
    vim.defer_fn(function() done(true) end, 120)
end

local function win_open() return ui._winid ~= nil and vim.api.nvim_win_is_valid(ui._winid) end

local function lines() return vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false) end

local function loaded(name) return { name = name, tasks = { h.lua('rtp', h.noop) } } end

-- Runs `fn` with the editor at the given size, then puts the size back.
local function with_size(columns, rows, fn)
    local old_columns, old_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = columns, rows
    local ok, err = pcall(fn)
    vim.o.columns, vim.o.lines = old_columns, old_lines
    if not ok then error(err, 0) end
end

-- A plugin whose tasks come from the factory, as a manifest entry's do.
local function generated(name, spec)
    return { name = name, tasks = factory.generate(vim.tbl_extend('force', { name = name }, spec)) }
end

test('there is one row per plugin in load order, with its state and its task count', function()
    local plugins = {}
    for i = 1, 6 do
        local fn = i == 3 and function() error('boom') end or h.noop
        table.insert(plugins, { name = 'plugin' .. i, tasks = { h.lua('rtp', h.noop), h.lua('load', fn) } })
    end
    h.register(plugins)
    h.run(plugins)
    with_size(200, 50, function()
        ui.open()
        local got = lines()
        h.eq(#got, 9)
        for i = 1, 6 do
            h.ok(got[i + 1]:find('plugin' .. i, 1, true), 'row ' .. i .. ' is ' .. got[i + 1])
        end
        h.ok(got[2]:find('✔ plugin1%s+later%s+loaded%s+2 of 2 tasks'), got[2])
        h.ok(got[4]:find('✘ plugin3%s+later%s+failed%s+2 of 2 tasks%s+boom'), got[4])
    end)
end)

test('a running row shows its work and updates in place until it is loaded', function()
    local plugin = { name = 'slow', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    h.register({ plugin })
    tasks.enqueue('slow', plugin)
    tasks.run_all()
    with_size(200, 50, function()
        h.ok(vim.wait(500, win_open), 'the window never opened')
        h.ok(vim.wait(500, function() return lines()[2]:find('installing', 1, true) end), lines()[2])
        h.ok(
            lines()[2]:find('▶ slow%s+later%s+installing%s+1 of 2 tasks%s+Receiving objects: 45%%'),
            lines()[2]
        )
        h.eq(lines()[1], ' Sarcina · 0 of 1 plugins · 1 running')
        release()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(500, function() return lines()[2]:find('loaded', 1, true) end), lines()[2])
        h.ok(lines()[2]:find('✔ slow%s+later%s+loaded%s+2 of 2 tasks'), lines()[2])
        h.eq(lines()[1], ' Sarcina · 1 of 1 plugins')
    end)
end)

test('the footer is the stats and the slowest plugins, the header the progress', function()
    local plugins = {
        { name = 'slow', tasks = { { id = 'rtp', type = 'w_slow' } } },
        loaded('fast'),
    }
    h.register(plugins)
    h.run(plugins)
    with_size(200, 50, function()
        ui.open()
        local got = lines()
        h.eq(got[1], ' Sarcina · 2 of 2 plugins')
        h.eq(got[#got - 1], ' ' .. window.summary(stats.get()))
        h.ok(got[#got]:find('^ slowest: slow %d+ms$'), got[#got])
    end)
end)

test('a row moves up when its plugin loads, so the rows keep the order of the loads', function()
    local held = { name = 'a', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    local fast = loaded('b')
    h.register({ held, fast })
    with_size(200, 50, function()
        ui.open()
        h.ok(lines()[2]:find('a%s+later%s+pending'), lines()[2])
        h.ok(lines()[3]:find('b%s+later%s+pending'), lines()[3])
        tasks.enqueue('a', held)
        tasks.enqueue('b', fast)
        tasks.run_all()
        h.ok(vim.wait(500, function() return lines()[2]:find('✔ b%s+later%s+loaded') end), lines()[2])
        h.ok(lines()[3]:find('▶ a%s+later%s+installing'), lines()[3])
        release()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(500, function() return lines()[3]:find('✔ a%s+later%s+loaded') end), lines()[3])
        h.ok(lines()[2]:find('✔ b%s+later%s+loaded'), lines()[2])
    end)
end)

test('the window is centered and as tall as its content', function()
    h.register({ loaded('a'), loaded('b'), loaded('c') })
    with_size(100, 40, function()
        ui.open()
        local config = vim.api.nvim_win_get_config(ui._winid)
        h.eq(config.height, 6)
        h.ok(config.width + 2 <= 80, 'wider than 80%: ' .. config.width)
        h.ok(math.abs(2 * config.col + config.width + 2 - 100) <= 1, 'not centered across')
        h.ok(math.abs(2 * config.row + config.height + 2 - 39) <= 1, 'not centered down')
    end)
end)

test('a long list is capped at 80% of the editor and scrolls inside the window', function()
    local plugins = {}
    for i = 1, 60 do
        table.insert(plugins, loaded(string.rep('n', 30) .. i))
    end
    h.register(plugins)
    with_size(100, 40, function()
        ui.open()
        local config = vim.api.nvim_win_get_config(ui._winid)
        h.eq({ config.width, config.height }, { 78, 29 })
        h.eq(#lines(), 63)
        h.ok(lines()[2]:find('…', 1, true), 'a long name was not cut: ' .. lines()[2])
    end)
end)

test('a resize redraws the window at the new size and keeps it centered', function()
    ui.init()
    h.register({ loaded('a') })
    with_size(100, 40, function()
        ui.open()
        local before = vim.api.nvim_win_get_config(ui._winid)
        vim.o.columns = 140
        vim.api.nvim_exec_autocmds('VimResized', {})
        h.ok(
            vim.wait(500, function() return vim.api.nvim_win_get_config(ui._winid).width > before.width end),
            'the window kept its old width'
        )
        local after = vim.api.nvim_win_get_config(ui._winid)
        h.ok(math.abs(2 * after.col + after.width + 2 - 140) <= 1, 'not centered across')
    end)
end)

test('an event redraws only the row of its plugin, the header and the footer', function()
    local held = { name = 'b', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    h.register({ loaded('a'), held, loaded('c') })
    ui.open()
    local touched = {}
    vim.api.nvim_buf_attach(ui._bufnr, false, {
        on_lines = function(_, _, _, first) touched[first] = true end,
    })
    tasks.enqueue('b', held)
    tasks.run_all()
    h.ok(vim.wait(500, function() return lines()[3]:find('installing', 1, true) end), lines()[3])
    h.eq({ touched[0], touched[1], touched[2], touched[3] }, { true, nil, true, nil })
    release()
    h.ok(tasks.wait(2000))
end)

test('the expand seam exists and does nothing yet', function()
    h.register({ loaded('a'), loaded('b') })
    ui.open()
    h.eq(window.expanded, {})
    h.eq(window.entry_at(1), nil)
    h.eq(window.entry_at(2), { kind = 'plugin', name = 'a' })
    h.eq(window.entry_at(3), { kind = 'plugin', name = 'b' })
    h.eq(window.entry_at(4), nil)
end)

test('an install of what is already on disk never opens the window', function()
    vim.fn.mkdir(paths.install('warmwin.nvim'), 'p')
    local plugin = generated('warmwin.nvim', { repo = 'x/warmwin' })
    h.register({ plugin })
    h.run({ plugin })
    vim.wait(300)
    h.eq(ui._winid, nil)
end)

if vim.fn.executable('git') == 1 then
    test('a real clone opens the window and its row ends loaded', function()
        local plugin = generated('clonewin.nvim', { repo = h.make_repo() })
        h.register({ plugin })
        tasks.enqueue(plugin.name, plugin)
        tasks.run_all(nil, { quiet = true })
        h.ok(vim.wait(2000, win_open), 'the window never opened for the clone')
        h.ok(tasks.wait(5000))
        h.ok(vim.wait(500, function() return lines()[2]:find('loaded', 1, true) end), lines()[2])
        h.ok(lines()[2]:find('✔ clonewin.nvim%s+later%s+loaded%s+2 of 2 tasks'), lines()[2])
    end)

    test(
        'a build that runs because the commit changed opens the window, one that is up to date does not',
        function()
            local repo = h.make_repo()
            vim.fn.system({ 'git', 'clone', '-q', repo, paths.install('buildwin.nvim') })
            local ran = 0
            local plugin = generated('buildwin.nvim', { repo = repo, build = function() ran = ran + 1 end })
            h.register({ plugin })
            h.run({ plugin })
            h.eq(ran, 1)
            h.ok(vim.wait(200, win_open), 'the window never opened for the build')
            ui.close()
            h.run({ plugin })
            vim.wait(300)
            h.eq(ran, 1)
            h.eq(ui._winid, nil)
        end
    )

    -- Starts Neovim for real with one plugin and reports whether the window opened and what it showed.
    local function run_child(spec)
        local specs = vim.fn.stdpath('config') .. '/lua/plugins'
        vim.fn.mkdir(specs, 'p')
        local file = specs .. '/window_child.lua'
        vim.fn.writefile({ 'return {', spec, '}' }, file)
        local script = vim.fn.tempname() .. '.lua'
        vim.fn.writefile({
            string.format('vim.opt.rtp:prepend(%q)', root),
            "require('sarcina').setup()",
            "require('sarcina.ui').close_delay = 60000",
            "vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()",
            '    vim.defer_fn(function()',
            "        require('sarcina.tasks').wait(10000)",
            '        vim.wait(200)',
            "        local ui = require('sarcina.ui')",
            '        io.stdout:write(vim.json.encode({',
            '            open = ui._winid ~= nil,',
            '            lines = ui._bufnr and vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false) or {},',
            '        }))',
            '        vim.cmd.qa({ bang = true })',
            '    end, 100)',
            'end })',
        }, script)
        local res = vim.system({ vim.v.progpath, '--headless', '-i', 'NONE', '-u', script }, { text = true })
            :wait(20000)
        vim.fn.delete(file)
        h.eq(res.code, 0, res.stderr)
        return vim.json.decode(res.stdout)
    end

    test('in a real startup a plugin that is not on disk opens the window and ends loaded', function()
        local spec = string.format(
            "    { name = 'winchild.nvim', repo = %q, config = function() end },",
            h.make_repo()
        )
        local seen = run_child(spec)
        h.eq(seen.open, true)
        h.ok(seen.lines[2]:find('✔ winchild.nvim%s+later%s+loaded%s+3 of 3 tasks'), vim.inspect(seen.lines))
    end)

    test('in a real startup with everything installed no window opens', function()
        vim.fn.mkdir(paths.install('winwarm.nvim'), 'p')
        local seen = run_child("    { name = 'winwarm.nvim', repo = 'x/winwarm', config = function() end },")
        h.eq(seen.open, false)
    end)
end

return tests
