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

local function header_text() return vim.api.nvim_buf_get_lines(ui._header_bufnr, 0, -1, false)[1] end

local function footer() return vim.api.nvim_buf_get_lines(ui._footer_bufnr, 0, -1, false) end

-- The first line of a window that shows, once the screen has caught up with a move of the cursor.
local function top_of(winid)
    vim.cmd('redraw')
    return vim.api.nvim_win_call(winid, function() return vim.fn.line('w0') end)
end

local function details() return vim.api.nvim_buf_get_lines(ui._detail_bufnr, 0, -1, false) end

local function details_text() return table.concat(details(), '\n') end

local function title_of(winid)
    local title = vim.api.nvim_win_get_config(winid).title
    if type(title) == 'table' then
        title = table.concat(
            vim.tbl_map(function(chunk) return type(chunk) == 'table' and chunk[1] or chunk end, title)
        )
    end
    return title
end

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
        h.eq(#got, 6)
        for i = 1, 6 do
            h.ok(got[i]:find('plugin' .. i, 1, true), 'row ' .. i .. ' is ' .. got[i])
        end
        h.ok(got[1]:find('✔ plugin1%s+later%s+loaded%s+2 of 2 tasks'), got[1])
        h.ok(got[1]:find('2 of 2 tasks ✔%s+[<%d%.]+ms'), 'a fast plugin has no time: ' .. got[1])
        h.ok(got[3]:find('✘ plugin3%s+later%s+failed%s+2 of 2 tasks%s+[<%d%.]+ms'), got[3])
        h.ok(details_text():find('detail%s+boom'), 'the failed plugin is selected: ' .. details_text())
    end)
end)

test('a running row shows its work, and the details show its output, until it is loaded', function()
    local plugin = { name = 'slow', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    h.register({ plugin })
    tasks.enqueue('slow', plugin)
    tasks.run_all()
    with_size(200, 50, function()
        h.ok(vim.wait(500, win_open), 'the window never opened')
        h.ok(vim.wait(500, function() return lines()[1]:find('installing', 1, true) end), lines()[1])
        h.ok(lines()[1]:find('▶ slow%s+later%s+installing%s+1 of 2 tasks'), lines()[1])
        h.eq(header_text(), ' Total: 1 plugin')
        h.ok(
            vim.wait(500, function() return details_text():find('Receiving objects: 45%', 1, true) end),
            details_text()
        )
        h.ok(details_text():find('▶ install%s+Receiving objects: 45%%'), details_text())
        release()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(500, function() return lines()[1]:find('loaded', 1, true) end), lines()[1])
        h.ok(lines()[1]:find('✔ slow%s+later%s+loaded%s+2 of 2 tasks'), lines()[1])
        h.eq(header_text(), ' Total: 1 plugin')
    end)
end)

test('the header counts the plugins and the footer is how many load when, with the startup time', function()
    local plugins = {
        { name = 'slow', tasks = { { id = 'rtp', type = 'w_slow' } } },
        loaded('fast'),
        { name = 'eager', timing = 'now', tasks = { h.lua('rtp', h.noop) } },
    }
    h.register(plugins)
    h.run(plugins)
    with_size(200, 50, function()
        ui.open()
        h.eq(header_text(), ' Total: 3 plugins')
        local numbers = stats.get()
        local got = footer()
        h.eq(#got, 1)
        local left =
            string.format(' Now %d, Later %d, Triggered %d', numbers.now, numbers.later, numbers.triggered)
        h.eq({ numbers.now, numbers.later, numbers.triggered }, { 1, 2, 0 })
        h.ok(vim.startswith(got[1], left), got[1])
        h.ok(got[1]:find('%s+Startup: [%d…]'), got[1])
        h.ok(not got[1]:find('slowest', 1, true), 'the slowest plugins are gone: ' .. got[1])
    end)
end)

test('the footer shows the startup time in milliseconds once the UI is up', function()
    h.register({ loaded('a') })
    require('sarcina.load')._reset(true)
    with_size(200, 50, function()
        ui.open()
        h.ok(footer()[1]:find('Startup: %d+ms%s*$'), footer()[1])
    end)
end)

test('a row moves up when its plugin loads, so the rows keep the order of the loads', function()
    local held = { name = 'a', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    local fast = loaded('b')
    h.register({ held, fast })
    with_size(200, 50, function()
        ui.open()
        h.ok(lines()[1]:find('a%s+later%s+pending'), lines()[1])
        h.ok(lines()[2]:find('b%s+later%s+pending'), lines()[2])
        tasks.enqueue('a', held)
        tasks.enqueue('b', fast)
        tasks.run_all()
        h.ok(vim.wait(500, function() return lines()[1]:find('✔ b%s+later%s+loaded') end), lines()[1])
        h.ok(lines()[2]:find('▶ a%s+later%s+installing'), lines()[2])
        release()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(500, function() return lines()[2]:find('✔ a%s+later%s+loaded') end), lines()[2])
        h.ok(lines()[1]:find('✔ b%s+later%s+loaded'), lines()[1])
    end)
end)

-- The highlight groups on line `lnum` (1-based) of the list.
local function groups_on(lnum)
    local ns = vim.api.nvim_get_namespaces().sarcina_window
    local found = {}
    for _, mark in
        ipairs(
            vim.api.nvim_buf_get_extmarks(
                ui._bufnr,
                ns,
                { lnum - 1, 0 },
                { lnum - 1, -1 },
                { details = true }
            )
        )
    do
        found[mark[4].hl_group] = true
    end
    return found
end

test(
    'the tasks widget is a pill in the colour of the state, with a check only when all tasks are done',
    function()
        local waiting = { name = 'waiting', tasks = { h.lua('rtp', h.noop) } }
        local plugins = {
            loaded('done'),
            { name = 'failed', tasks = { h.lua('rtp', function() error('no') end) } },
            { name = 'running', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } },
            { name = 'idle', tasks = { h.lua('rtp', h.noop) } },
            waiting,
        }
        h.register(plugins)
        -- `waiting` is a plugin whose trigger is armed and whose tasks have not run.
        h.run({ plugins[1], plugins[2] })
        tasks.enqueue('running', plugins[3])
        local trigger = { id = 'load_trigger', type = 'lua', fn = h.noop }
        tasks.run_all()
        with_size(200, 50, function()
            ui.open()
            h.ok(vim.wait(500, function() return lines()[3]:find('installing', 1, true) end), lines()[3])
            local got = lines()
            h.ok(got[1]:find('2 of 1 tasks') == nil, got[1])
            h.ok(got[1]:find(' 1 of 1 tasks ✔ '), got[1])
            h.ok(
                got[2]:find(' 1 of 1 tasks %s') and not got[2]:find('✔', 5, true),
                'no check for a failure: ' .. got[2]
            )
            h.ok(got[3]:find(' 1 of 2 tasks '), got[3])
            h.ok(groups_on(1).SarcinaTaskDone, 'a loaded plugin has a green pill')
            h.ok(groups_on(2).SarcinaTaskFailed, 'a failed plugin has a red pill')
            h.ok(groups_on(3).SarcinaTaskRunning, 'a running plugin has a blue pill')
            h.ok(groups_on(5).SarcinaTaskIdle, 'a plugin that has not started has a grey pill')
            release()
            h.ok(tasks.wait(2000))
        end)
        local _ = trigger
    end
)

test('a plugin that waits for its trigger is yellow, with a yellow pill', function()
    local plugin = {
        name = 'waits',
        timing = 'trigger',
        triggers = { cmd = { 'WaitsCmd' } },
        tasks = {
            { id = 'load_trigger', type = 'trigger', triggers = { cmd = { 'WaitsCmd' } } },
            h.lua('rtp', h.noop),
        },
    }
    h.register({ plugin })
    h.run({ { name = 'waits', tasks = { plugin.tasks[1] } } })
    with_size(200, 50, function()
        ui.open()
        h.ok(lines()[1]:find('○ waits%s+trigger%s+waiting'), lines()[1])
        local groups = groups_on(1)
        h.ok(groups.SarcinaWaiting, 'the glyph and the state are not yellow')
        h.ok(groups.SarcinaTaskWaiting, 'the pill is not yellow')
        h.ok(not lines()[1]:find('✔', 1, true), 'a plugin that waits is not complete: ' .. lines()[1])
        h.eq(vim.api.nvim_get_hl(0, { name = 'SarcinaWaiting', link = true }).link, 'DiagnosticWarn')
    end)
end)

test(
    'a pill takes its colour from the colorscheme: a light background and a darker text of one hue',
    function()
        vim.api.nvim_set_hl(0, 'DiagnosticOk', { fg = 0x33cc33 })
        vim.cmd('highlight clear SarcinaTaskDone')
        window.define_highlights()
        local pill = vim.api.nvim_get_hl(0, { name = 'SarcinaTaskDone', link = false })
        local function channels(color)
            return { bit.rshift(color, 16), bit.band(bit.rshift(color, 8), 0xff), bit.band(color, 0xff) }
        end
        local fg, bg = channels(pill.fg), channels(pill.bg)
        h.ok(fg[2] > fg[1] and fg[2] > fg[3], 'the text is not green: ' .. vim.inspect(fg))
        h.ok(bg[2] > bg[1] and bg[2] >= bg[3], 'the background is not green: ' .. vim.inspect(bg))
        h.ok(bg[1] + bg[2] + bg[3] > fg[1] + fg[2] + fg[3], 'the background is not lighter than the text')
        h.ok(bg[2] > 200, 'the background is not light: ' .. vim.inspect(bg))
    end
)

test('four windows are stacked and centered, 80% by 80% of the editor', function()
    h.register({ loaded('a'), loaded('b'), loaded('c') })
    with_size(120, 40, function()
        ui.open()
        local function config(win) return vim.api.nvim_win_get_config(win) end
        local header, list = config(ui._header_winid), config(ui._winid)
        local detail, bottom = config(ui._detail_winid), config(ui._footer_winid)
        -- 96 columns and 31 rows: a header of 3 rows, a footer of 3, and 25 for the panes with their borders.
        h.eq({ header.width + 2, bottom.width + 2, list.width + detail.width + 4 }, { 96, 96, 96 })
        h.eq({ header.height, bottom.height, list.height, detail.height }, { 1, 1, 23, 23 })
        h.eq(list.row, header.row + 3)
        h.eq(detail.row, list.row)
        h.eq(bottom.row, list.row + list.height + 2)
        h.eq(detail.col, list.col + list.width + 2)
        h.eq({ header.col, bottom.col }, { list.col, list.col })
        h.eq(bottom.row + bottom.height + 2 - header.row, 31)
        h.ok(math.abs(2 * header.col + 96 - 120) <= 1, 'not centered across')
        h.ok(math.abs(2 * header.row + 31 - 39) <= 1, 'not centered down')
        h.ok(list.width <= math.floor(92 * 0.55), 'the list is wider than 55%: ' .. list.width)
        h.eq({ header.focusable, detail.focusable, bottom.focusable }, { false, false, false })
    end)
end)

test('the header and the footer stay in view while the list scrolls', function()
    local plugins = {}
    for i = 1, 60 do
        table.insert(plugins, loaded(string.rep('n', 30) .. i))
    end
    h.register(plugins)
    with_size(100, 40, function()
        ui.open()
        local list = vim.api.nvim_win_get_config(ui._winid)
        h.eq({ list.width, list.height }, { 78, 23 })
        h.eq(#lines(), 60)
        h.ok(lines()[1]:find('…', 1, true), 'a long name was not cut: ' .. lines()[1])
        local before = { header_text(), footer(), vim.api.nvim_win_get_config(ui._header_winid).row }
        local footer_row = vim.api.nvim_win_get_config(ui._footer_winid).row
        h.eq(top_of(ui._winid), 1)
        vim.api.nvim_win_set_cursor(ui._winid, { 60, 0 })
        h.ok(top_of(ui._winid) > 1, 'the list did not scroll')
        h.eq(header_text(), before[1])
        h.eq(footer(), before[2])
        h.eq(vim.api.nvim_win_get_config(ui._header_winid).row, before[3])
        h.eq(vim.api.nvim_win_get_config(ui._footer_winid).row, footer_row)
    end)
end)

test('with no room for two panes the list takes the width and its rows keep the detail text', function()
    local held = { name = 'a', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    h.register({ held })
    tasks.enqueue('a', held)
    tasks.run_all()
    with_size(100, 40, function()
        h.ok(vim.wait(500, win_open), 'the window never opened')
        h.ok(
            vim.wait(500, function() return lines()[1]:find('Receiving objects: 45%', 1, true) end),
            lines()[1]
        )
        h.eq(ui._detail_winid, nil)
        release()
        h.ok(tasks.wait(2000))
    end)
end)

test(
    'a resize across the threshold opens and closes the details pane, and keeps all of it centered',
    function()
        ui.init()
        h.register({ loaded('a') })
        with_size(100, 40, function()
            ui.open()
            h.eq(ui._detail_winid, nil)
            vim.o.columns = 140
            vim.api.nvim_exec_autocmds('VimResized', {})
            h.ok(
                vim.wait(500, function() return ui._detail_winid ~= nil end),
                'the details pane did not appear'
            )
            local list = vim.api.nvim_win_get_config(ui._winid)
            local detail = vim.api.nvim_win_get_config(ui._detail_winid)
            h.eq(list.width + detail.width + 4, 112)
            h.eq(vim.api.nvim_win_get_config(ui._header_winid).width + 2, 112)
            h.ok(math.abs(2 * list.col + 112 - 140) <= 1, 'not centered across')
            vim.o.columns = 100
            vim.api.nvim_exec_autocmds('VimResized', {})
            h.ok(vim.wait(500, function() return ui._detail_winid == nil end), 'the details pane stayed')
            h.eq(vim.api.nvim_win_get_config(ui._winid).width, 78)
            h.eq(vim.api.nvim_win_get_config(ui._footer_winid).width, 78)
        end)
    end
)

test('an event redraws only the row of its plugin in the list, and the header and the footer', function()
    local held = { name = 'b', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    h.register({ loaded('a'), held, loaded('c') })
    ui.open()
    local touched, chrome = {}, 0
    vim.api.nvim_buf_attach(ui._bufnr, false, {
        on_lines = function(_, _, _, first) touched[first] = true end,
    })
    for _, buf in ipairs({ ui._header_bufnr, ui._footer_bufnr }) do
        vim.api.nvim_buf_attach(buf, false, { on_lines = function() chrome = chrome + 1 end })
    end
    tasks.enqueue('b', held)
    tasks.run_all()
    h.ok(vim.wait(500, function() return lines()[2]:find('installing', 1, true) end), lines()[2])
    h.eq({ touched[0], touched[1], touched[2] }, { nil, true, nil })
    h.ok(chrome >= 2, 'the header and the footer were not redrawn')
    release()
    h.ok(tasks.wait(2000))
end)

test('the details show where a plugin comes from, what it waits for, and each of its tasks', function()
    local plugin = {
        name = 'detailed',
        timing = 'trigger',
        repo = 'owner/detailed',
        deps = { 'depone', 'deptwo' },
        origin = vim.fn.expand('~') .. '/specs/detailed.lua',
        triggers = { cmd = { 'DetailedCmd' } },
        tasks = { h.lua('rtp', h.noop), { id = 'load', type = 'w_slow' } },
    }
    h.register({ plugin })
    h.run({ plugin })
    require('sarcina.scheduler').register('detailed', { triggers = plugin.triggers })
    with_size(200, 50, function()
        ui.open()
        local text = details_text()
        for _, expected in ipairs({
            'state%s+✔ loaded',
            'tasks%s+2 of 2 tasks · %d+ms',
            'timing%s+trigger',
            'src%s+owner/detailed',
            'deps%s+depone, deptwo',
            'triggers%s+:DetailedCmd',
            'armed%s+waiting',
            'origin%s+~/specs/detailed%.lua',
            '✔ rtp',
            '✔ load%s+%d+ms',
        }) do
            h.ok(text:find(expected), expected .. ' is not in:\n' .. text)
        end
        local path = vim.fn.fnamemodify(paths.install('detailed'), ':~')
        h.ok(text:find('path%s+' .. vim.pesc(path)), text)
        h.eq(title_of(ui._detail_winid), ' detailed ')
        h.eq({ vim.wo[ui._detail_winid].wrap, vim.wo[ui._detail_winid].breakindent }, { true, true })
    end)
end)

test(
    'the details scroll with ctrl-d and ctrl-u from the list, and start at the top for another plugin',
    function()
        local steps = {}
        for i = 1, 30 do
            table.insert(steps, h.lua('step' .. i, h.noop))
        end
        h.register({ { name = 'long', tasks = steps }, loaded('b') })
        with_size(200, 30, function()
            ui.open()
            local function press(key)
                local map = vim.api.nvim_buf_call(
                    ui._bufnr,
                    function() return vim.fn.maparg(key, 'n', false, true) end
                )
                map.callback()
            end
            h.eq(top_of(ui._detail_winid), 1)
            press('<C-d>')
            local scrolled = top_of(ui._detail_winid)
            h.ok(scrolled > 1, 'ctrl-d did not scroll the details')
            press('<C-u>')
            h.ok(top_of(ui._detail_winid) < scrolled, 'ctrl-u did not scroll back')
            press('<C-d>')
            h.ok(top_of(ui._detail_winid) > 1)
            vim.api.nvim_win_set_cursor(ui._winid, { 2, 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            h.eq(title_of(ui._detail_winid), ' b ')
            h.eq(top_of(ui._detail_winid), 1)
        end)
    end
)

if vim.fn.executable('git') == 1 then
    test('the details show the commit once it has been read', function()
        local dir = paths.install('revplug')
        vim.fn.system({ 'git', 'clone', '-q', h.make_repo(), dir })
        local expected = vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', '--short', 'HEAD' }))
        h.register({ loaded('revplug') })
        with_size(200, 50, function()
            ui.open()
            h.ok(
                vim.wait(2000, function() return details_text():find('rev%s+' .. expected) end),
                details_text()
            )
        end)
    end)
end

test('the details follow the cursor of the list', function()
    h.register({ loaded('a'), loaded('b'), loaded('c') })
    with_size(200, 50, function()
        ui.open()
        h.eq(title_of(ui._detail_winid), ' a ')
        for line, name in pairs({ [2] = ' b ', [3] = ' c ', [1] = ' a ' }) do
            vim.api.nvim_win_set_cursor(ui._winid, { line, 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            h.eq(title_of(ui._detail_winid), name)
        end
    end)
end)

test('the details follow the plugin at work while you are not in the window', function()
    local held = { name = 'b', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    h.register({ loaded('a'), held })
    tasks.enqueue('b', held)
    tasks.run_all()
    with_size(200, 50, function()
        h.ok(vim.wait(500, win_open), 'the window never opened')
        h.ok(
            vim.wait(
                500,
                function()
                    return ui._detail_winid
                        and title_of(ui._detail_winid) == ' b '
                        and details_text():find('Receiving objects', 1, true)
                end
            ),
            'the details did not follow the plugin at work'
        )
        release()
        h.ok(tasks.wait(2000))
    end)
end)

test(
    'a user in the window keeps their plugin, and events for other plugins do not redraw the details',
    function()
        local held = { name = 'b', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
        h.register({ loaded('a'), held })
        with_size(200, 50, function()
            ui.open()
            h.ok(
                vim.wait(1000, function() return not details_text():find('rev%s') end),
                'the commit never settled'
            )
            local redrawn = 0
            vim.api.nvim_buf_attach(
                ui._detail_bufnr,
                false,
                { on_lines = function() redrawn = redrawn + 1 end }
            )
            tasks.enqueue('b', held)
            tasks.run_all()
            h.ok(vim.wait(500, function() return lines()[2]:find('installing', 1, true) end), lines()[2])
            h.eq(redrawn, 0)
            h.eq(title_of(ui._detail_winid), ' a ')
            release()
            h.ok(tasks.wait(2000))
            -- b loaded and moved above a; the cursor went with a.
            h.ok(vim.wait(500, function() return window.line('a') == 2 end), 'the rows did not move')
            h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], 2)
            h.eq(title_of(ui._detail_winid), ' a ')
        end)
    end
)

test('closing the list closes the other three windows, and so does q', function()
    h.register({ loaded('a') })
    local function others() return { ui._header_winid, ui._detail_winid, ui._footer_winid } end
    with_size(200, 50, function()
        ui.open()
        local first = others()
        h.eq(#vim.tbl_keys(first), 3)
        vim.api.nvim_win_close(ui._winid, true)
        for _, win in ipairs(first) do
            h.eq(vim.api.nvim_win_is_valid(win), false)
        end
        h.eq(others(), {})
        ui.open()
        local second = others()
        local map = vim.api.nvim_buf_call(
            ui._bufnr,
            function() return vim.fn.maparg('q', 'n', false, true) end
        )
        map.callback()
        for _, win in ipairs(second) do
            h.eq(vim.api.nvim_win_is_valid(win), false)
        end
        h.eq({ ui._winid, ui._header_winid, ui._detail_winid, ui._footer_winid }, {})
    end)
end)

test('entry_at maps the lines of the list to their plugins', function()
    h.register({ loaded('a'), loaded('b') })
    ui.open()
    h.eq(window.entry_at(1), { kind = 'plugin', name = 'a' })
    h.eq(window.entry_at(2), { kind = 'plugin', name = 'b' })
    h.eq(window.entry_at(3), nil)
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
        h.ok(vim.wait(500, function() return lines()[1]:find('loaded', 1, true) end), lines()[1])
        h.ok(lines()[1]:find('✔ clonewin.nvim%s+later%s+loaded%s+2 of 2 tasks'), lines()[1])
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
        h.ok(seen.lines[1]:find('✔ winchild.nvim%s+later%s+loaded%s+3 of 3 tasks'), vim.inspect(seen.lines))
    end)

    test('in a real startup with everything installed no window opens', function()
        vim.fn.mkdir(paths.install('winwarm.nvim'), 'p')
        local seen = run_child("    { name = 'winwarm.nvim', repo = 'x/winwarm', config = function() end },")
        h.eq(seen.open, false)
    end)
end

return tests
