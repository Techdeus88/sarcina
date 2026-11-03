local h = require('helpers')
local executors = require('sarcina.executors')
local factory = require('sarcina.task_factory')
local paths = require('sarcina.paths')
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

-- Every line of the list: the blank lines at the ends, the Updates heading when there is one, and the rows.
local function buffer_lines() return vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false) end

-- The rows of the plugins, in the order the list shows them, without the heading and the blank lines.
local function lines()
    local rows = {}
    for lnum, line in ipairs(buffer_lines()) do
        local entry = window.entry_at(lnum)
        if entry and entry.kind == 'plugin' then table.insert(rows, line) end
    end
    return rows
end

local function header_all() return vim.api.nvim_buf_get_lines(ui._header_bufnr, 0, -1, false) end

local function header_text() return header_all()[1] end

local function footer() return vim.api.nvim_buf_get_lines(ui._footer_bufnr, 0, -1, false) end

-- The first line of a window that shows, once the screen has caught up with a move of the cursor.
local function top_of(winid)
    vim.cmd('redraw')
    return vim.api.nvim_win_call(winid, function() return vim.fn.line('w0') end)
end

local function details() return vim.api.nvim_buf_get_lines(ui._detail_bufnr, 0, -1, false) end

local function details_text() return table.concat(details(), '\n') end

-- The name of the plugin the details show: the line under the blank one at the top of the details.
local function detail_name()
    local line = details()[2]
    return line and vim.trim(line) or nil
end

local function loaded(name) return { name = name, tasks = { h.lua('rtp', h.noop) } } end

-- The row of the plugin `name` in the list.
local function row_of(name)
    for _, line in ipairs(lines()) do
        if line:find('^%s+' .. vim.pesc(name) .. '%s') then return line end
    end
end

-- Runs `fn` in the view `name`, then puts the default view back.
local function in_view(name, fn)
    window.view = name
    local ok, err = pcall(fn)
    window.view = 'main'
    if not ok then error(err, 0) end
end

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
        h.ok(got[1]:find('^   plugin1%s+%([<%d%.]+ms%)%s+later%s+.*2/2%s+tasks ✔.*loaded'), got[1])
        h.ok(got[3]:find('^   plugin3%s+%([<%d%.]+ms%)%s+later%s+.*2/2%s+tasks ✘.*failed'), got[3])
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
        h.ok(lines()[1]:find('^   slow%s+.*later%s+.*1/2%s+tasks ▶.*installing'), lines()[1])
        -- The right of the header follows the work: what kind, how far, the plugin at it, and a bar.
        h.ok(
            header_text():find('^ Total: 1 plugin%s+Sarcina%s+⤓ Installing 0/1 plugin · slow  .-   0%% $'),
            header_text()
        )
        h.ok(
            vim.wait(500, function() return details_text():find('Receiving objects: 45%', 1, true) end),
            details_text()
        )
        h.ok(details_text():find('▶ install%s+Receiving objects: 45%%'), details_text())
        release()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(500, function() return lines()[1]:find('loaded', 1, true) end), lines()[1])
        h.ok(lines()[1]:find('^   slow%s+.*later%s+.*2/2%s+tasks ✔.*loaded'), lines()[1])
        h.ok(header_text():find('^ Total: 1 plugin%s+Sarcina$'), header_text())
        -- The counts of what the session did sit on the left, after loaded and not loaded.
        h.ok(header_all()[2]:find('^ ● 1  ○ 0  ⤓ 1'), header_all()[2])
    end)
end)

test('the work in the header says plugins for more than one, and the end of the run counts tasks', function()
    local held = { name = 'slow', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    local quick = { name = 'quick', tasks = { h.lua('install', h.noop), h.lua('rtp', h.noop) } }
    h.register({ held, quick })
    tasks.enqueue('quick', quick)
    tasks.enqueue('slow', held)
    tasks.run_all()
    with_size(200, 50, function()
        h.ok(vim.wait(500, win_open), 'the window never opened')
        h.ok(
            vim.wait(500, function() return header_text():find('Installing 1/2', 1, true) end),
            header_text()
        )
        h.ok(header_text():find('⤓ Installing 1/2 plugins · slow', 1, true), header_text())
        h.ok(header_all()[2]:find('/4 tasks', 1, true), header_all()[2])
        release()
        h.ok(tasks.wait(2000))
    end)
    h.ok(h.notified('4 tasks done'), vim.inspect(h.notes))
    h.notes = {}
    require('sarcina.ui')._messages = h.notes
    h.run({ { name = 'one', tasks = { h.lua('rtp', h.noop) } } })
    h.ok(h.notified('1 task done'), vim.inspect(h.notes))
    h.ok(not h.notified('1 tasks'), vim.inspect(h.notes))
end)

test(
    'plural says the word once for one and adds an s for any other count',
    function()
        h.eq(
            { ui.plural(0, 'plugin'), ui.plural(1, 'plugin'), ui.plural(4, 'plugin') },
            { '0 plugins', '1 plugin', '4 plugins' }
        )
    end
)

test(
    'the header counts the plugins and the footer points at the select view, with the startup time',
    function()
        local plugins = {
            { name = 'slow', tasks = { { id = 'rtp', type = 'w_slow' } } },
            loaded('fast'),
            { name = 'eager', timing = 'now', tasks = { h.lua('rtp', h.noop) } },
        }
        h.register(plugins)
        h.run(plugins)
        with_size(200, 50, function()
            ui.open()
            h.ok(header_text():find('^ Total: 3 plugins%s+Sarcina$'), header_text())
            local got = footer()
            h.eq(#got, 1)
            h.ok(vim.startswith(got[1], ' v to select plugins'), got[1])
            h.ok(not got[1]:find('Now %d'), 'the timing numbers are in the sections: ' .. got[1])
            h.ok(got[1]:find('%s+Startup: [%d…]'), got[1])
            h.ok(not got[1]:find('slowest', 1, true), 'the slowest plugins are gone: ' .. got[1])
        end)
    end
)

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
        h.ok(lines()[1]:find('^   a%s+later%s+.*tasks …'), lines()[1])
        h.ok(lines()[2]:find('^   b%s+later%s+.*tasks …'), lines()[2])
        tasks.enqueue('a', held)
        tasks.enqueue('b', fast)
        tasks.run_all()
        h.ok(
            vim.wait(500, function() return lines()[1]:find('^   b%s+.*later%s+.*tasks ✔') end),
            lines()[1]
        )
        h.ok(lines()[2]:find('^   a%s+.*later%s+.*tasks ▶'), lines()[2])
        release()
        h.ok(tasks.wait(2000))
        h.ok(
            vim.wait(500, function() return lines()[2]:find('^   a%s+.*later%s+.*tasks ✔') end),
            lines()[2]
        )
        h.ok(lines()[1]:find('^   b%s+.*later%s+.*tasks ✔'), lines()[1])
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
        local plugins = {
            loaded('done'),
            { name = 'failed', tasks = { h.lua('rtp', function() error('no') end) } },
            { name = 'running', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } },
            loaded('idle'),
        }
        h.register(plugins)
        h.run({ plugins[1], plugins[2] })
        tasks.enqueue('running', plugins[3])
        tasks.run_all()
        with_size(200, 50, function()
            ui.open()
            h.ok(vim.wait(500, function() return lines()[3]:find('installing', 1, true) end), lines()[3])
            local got = lines()
            h.ok(got[1]:find(' 1/1 %s*tasks ✔ '), 'a loaded plugin is checked: ' .. got[1])
            h.ok(
                got[2]:find(' 1/1 %s*tasks ✘ ') and not got[2]:find('✔', 1, true),
                'a failure is not: ' .. got[2]
            )
            h.ok(got[3]:find(' 1/2 %s*tasks ▶ '), got[3])
            h.ok(got[4]:find(' 0/1 %s*tasks … '), got[4])
            -- Each widget has four parts, in the colour of its state: the two ends, the count and the label.
            for name, kind in pairs({ done = 'Done', failed = 'Failed', running = 'Running', idle = 'Idle' }) do
                local line = window.line(name)
                local groups = groups_on(line)
                for _, suffix in ipairs({ 'Left', 'Count', '', 'Right' }) do
                    h.ok(
                        groups['SarcinaPill' .. kind .. suffix],
                        'row ' .. line .. ' has no SarcinaPill' .. kind .. suffix
                    )
                end
            end
            release()
            h.ok(tasks.wait(2000))
        end)
    end
)

test('the tasks widget has rounded ends unless rounded is off', function()
    local cap_left, cap_right = vim.fn.nr2char(0xe0b6), vim.fn.nr2char(0xe0b4)
    h.register({
        loaded('a'),
        { name = 'bb', tasks = { h.lua('rtp', function() error('no') end) } },
        loaded('c'),
    })
    h.run({ loaded('a'), { name = 'bb', tasks = { h.lua('rtp', function() error('no') end) } } })
    with_size(200, 50, function()
        ui.open()
        for _, line in ipairs(lines()) do
            h.ok(
                line:find(cap_left, 1, true) and line:find(cap_right, 1, true),
                'a row has no round ends: ' .. line
            )
        end
        ui.configure({ rounded = false })
        ui.open()
        for _, line in ipairs(lines()) do
            h.ok(
                not line:find(cap_left, 1, true) and not line:find(cap_right, 1, true),
                'a flat row has ends: ' .. line
            )
        end
        ui.configure(nil)
        h.eq(window.rounded, true)
    end)
end)

test('the parts of a row are one space apart, with no padding after a short name', function()
    local plugins = { loaded('a'), loaded('a-much-longer-name.nvim') }
    h.register(plugins)
    h.run(plugins)
    with_size(200, 50, function()
        ui.configure({ rounded = false })
        ui.open()
        for _, name in ipairs({ 'a', 'a-much-longer-name.nvim' }) do
            local row = row_of(name)
            h.ok(row:find('^   ' .. vim.pesc(name) .. ' %([<%d%.]+ms%) later  1/1  tasks ✔  loaded$'), row)
        end
        ui.configure(nil)
    end)
end)

test(
    'a row is the name, its load time in brackets, when it loads, the task pill and the status message',
    function()
        local plugins = {
            loaded('plugin'),
            { name = 'broken', tasks = { h.lua('rtp', function() error('it broke') end) } },
            { name = 'running', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } },
        }
        h.register(plugins)
        h.run({ plugins[1], plugins[2] })
        tasks.enqueue('running', plugins[3])
        tasks.run_all()
        with_size(200, 50, function()
            ui.open()
            h.ok(
                vim.wait(500, function() return row_of('running'):find('installing · Receiv', 1, true) end),
                row_of('running')
            )
            -- name, (load time), when it loads, count/total tasks and the icon of the state, status message
            h.ok(
                row_of('plugin'):find(
                    '^   plugin%s+%([<%d%.]+ms%)%s+later%s+.-1/1%s+tasks ✔.-%s+loaded%s*$'
                ),
                row_of('plugin')
            )
            h.ok(
                row_of('broken'):find(
                    '^   broken%s+%([<%d%.]+ms%)%s+later%s+.-1/1%s+tasks ✘.-%s+failed · it broke%s*$'
                ),
                row_of('broken')
            )
            h.ok(
                row_of('running'):find('^   running%s+later%s+.-1/2%s+tasks ▶.-%s+installing · Receiv'),
                row_of('running')
            )
            h.ok(not row_of('plugin'):find('^   ✔'), 'a row starts with its name, not an icon')
            release()
            h.ok(tasks.wait(2000))
        end)
    end
)

test(
    'the main view has room for the status message, and in a narrow list it goes before the name is cut',
    function()
        local name = 'a-plugin-with-a-rather-long-name.nvim'
        local held = { name = name, tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
        h.register({ held })
        tasks.enqueue(name, held)
        tasks.run_all()
        with_size(140, 40, function()
            h.ok(vim.wait(500, win_open), 'the window never opened')
            h.ok(vim.wait(500, function() return lines()[1]:find('installing', 1, true) end), lines()[1])
            h.ok(lines()[1]:find(name, 1, true), 'the name was cut: ' .. lines()[1])
            h.eq(ui._detail_winid ~= nil, true)
            in_view('split', function()
                ui.open()
                local row = lines()[1]
                h.ok(row:find('tasks ▶', 1, true), row)
                h.ok(
                    not row:find('installing', 1, true),
                    'half the window has no room for the message: ' .. row
                )
                h.ok(row:find('^   a%-plugin%-with.-… later'), 'the name was not cut to fit: ' .. row)
                h.ok(vim.fn.strdisplaywidth(row) <= vim.api.nvim_win_get_config(ui._winid).width, row)
            end)
            release()
            h.ok(tasks.wait(2000))
        end)
    end
)

test('a long status message, such as the error of a build, shows in full in the main view', function()
    local why = 'make: *** No rule to make target build. Stop.'
    local broken = { name = 'broken', tasks = { h.lua('build', function() error(why, 0) end) } }
    h.register({ broken })
    h.run({ broken })
    with_size(200, 50, function()
        ui.open()
        h.ok(row_of('broken'):find('failed · ' .. vim.pesc(why) .. '%s*$'), row_of('broken'))
    end)
end)

test(
    '= switches between 70/30 and 50/50, keeps the plugin under the cursor, and the footer says what = does',
    function()
        h.register({ loaded('a'), loaded('b'), loaded('c') })
        with_size(120, 40, function()
            ui.open()
            vim.api.nvim_set_current_win(ui._winid)
            vim.api.nvim_win_set_cursor(ui._winid, { window.line('b'), 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            local function widths()
                return {
                    vim.api.nvim_win_get_config(ui._winid).width,
                    vim.api.nvim_win_get_config(ui._detail_winid).width,
                }
            end
            local function footer_hint()
                local text = vim.api.nvim_win_get_config(ui._footer_winid).footer
                return type(text) == 'table' and text[1][1] or text
            end
            h.eq(widths(), { 64, 28 })
            h.ok(footer_hint():find('= 50/50', 1, true), footer_hint())
            vim.api.nvim_feedkeys('=', 'x', false)
            h.eq(window.view, 'split')
            h.eq(widths(), { 46, 46 })
            h.ok(footer_hint():find('= 70/30', 1, true), footer_hint())
            h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], window.line('b'))
            h.eq(window.selected(), 'b')
            -- The header and the footer keep the whole width.
            h.eq(vim.api.nvim_win_get_config(ui._header_winid).width + 2, 96)
            vim.api.nvim_feedkeys('=', 'x', false)
            h.eq({ window.view, widths() }, { 'main', { 64, 28 } })
            -- The view stays for the next time the window opens.
            vim.api.nvim_feedkeys('=', 'x', false)
            ui.close()
            ui.open()
            h.eq(widths(), { 46, 46 })
            window.view = 'main'
        end)
    end
)

test('- makes the window 95% tall and back, the extra rows all for the list and the details', function()
    h.register({ loaded('a'), loaded('b') })
    with_size(120, 40, function()
        ui.open()
        vim.api.nvim_set_current_win(ui._winid)
        local function config(win) return vim.api.nvim_win_get_config(win) end
        local function heights()
            return {
                config(ui._header_winid).height,
                config(ui._winid).height,
                config(ui._detail_winid).height,
                config(ui._footer_winid).height,
            }
        end
        local function footer_hint()
            local text = config(ui._footer_winid).footer
            return type(text) == 'table' and text[1][1] or text
        end
        -- 39 rows: 31 of them regular, 37 extended; the header (2) and the footer (1) stay as they are.
        h.eq(heights(), { 2, 22, 22, 1 })
        h.ok(footer_hint():find('- taller', 1, true), footer_hint())
        vim.api.nvim_feedkeys('-', 'xt', false)
        h.eq(window.height, 'extended')
        h.eq(heights(), { 2, 28, 28, 1 })
        h.ok(footer_hint():find('- shorter', 1, true), footer_hint())
        local header, footer_win = config(ui._header_winid), config(ui._footer_winid)
        h.eq(footer_win.row + footer_win.height + 2 - header.row, 37)
        h.ok(math.abs(2 * header.row + 37 - 39) <= 1, 'not centered down')
        -- The widths and the view do not change.
        h.eq({ config(ui._winid).width, config(ui._detail_winid).width }, { 64, 28 })
        vim.api.nvim_feedkeys('-', 'xt', false)
        h.eq({ window.height, heights() }, { 'regular', { 2, 22, 22, 1 } })
    end)
end)

test('ui.height picks how tall the window opens, and an unknown one warns and uses regular', function()
    ui.configure({ height = 'extended' })
    h.eq(window.height, 'extended')
    ui.configure({ height = 'huge' })
    h.eq(window.height, 'regular')
    h.ok(h.notified('Unknown ui.height huge, using regular'), vim.inspect(h.notes))
end)

test('ui.view picks the view the window opens in, and an unknown one warns and uses main', function()
    ui.configure({ view = 'split' })
    h.eq(window.view, 'split')
    ui.configure({ view = 'wide' })
    h.eq(window.view, 'main')
    h.ok(h.notified('Unknown ui.view wide, using main'), vim.inspect(h.notes))
    ui.configure(nil)
    h.eq(window.view, 'main')
end)

test('the src of a plugin is the URL it is cloned from', function()
    h.register({
        { name = 'short', repo = 'owner/short', tasks = { h.lua('rtp', h.noop) } },
        { name = 'full', repo = 'https://example.com/team/full.git', tasks = { h.lua('rtp', h.noop) } },
        { name = 'file', repo = 'file:///tmp/file-remote', tasks = { h.lua('rtp', h.noop) } },
    })
    with_size(200, 50, function()
        ui.open()
        for name, expected in pairs({
            short = 'https://github.com/owner/short',
            full = 'https://example.com/team/full.git',
            file = 'file:///tmp/file-remote',
        }) do
            vim.api.nvim_win_set_cursor(ui._winid, { window.line(name), 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            h.ok(details_text():find('src%s+' .. vim.pesc(expected) .. '\n'), details_text())
        end
    end)
end)

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
        h.ok(lines()[1]:find('^   waits%s+.*trigger%s+.*1/2%s+tasks ○.*waiting for :Waits'), lines()[1])
        local groups = groups_on(window.line('waits'))
        h.ok(groups.SarcinaWaiting, 'the glyph and the state are not yellow')
        h.ok(groups.SarcinaPillWaitingCount and groups.SarcinaPillWaiting, 'the pill is not yellow')
        h.ok(not lines()[1]:find('✔', 1, true), 'a plugin that waits is not complete: ' .. lines()[1])
        h.eq(vim.api.nvim_get_hl(0, { name = 'SarcinaWaiting', link = true }).link, 'DiagnosticWarn')
    end)
end)

test(
    'a pill takes its colour from the colorscheme: a bold dark count on it, a light label with darker text',
    function()
        vim.api.nvim_set_hl(0, 'DiagnosticOk', { fg = 0x33cc33 })
        for _, suffix in ipairs({ 'Left', 'Count', '', 'Right' }) do
            vim.cmd('highlight clear SarcinaPillDone' .. suffix)
        end
        window.define_highlights()
        local function get(suffix)
            return vim.api.nvim_get_hl(0, { name = 'SarcinaPillDone' .. suffix, link = false })
        end
        local function channels(color)
            return { bit.rshift(color, 16), bit.band(bit.rshift(color, 8), 0xff), bit.band(color, 0xff) }
        end
        local function total(color)
            return vim.iter(channels(color)):fold(0, function(a, b) return a + b end)
        end
        local count, label, left, right = get('Count'), get(''), get('Left'), get('Right')
        h.eq(count.bg, 0x33cc33)
        h.eq(count.bold, true)
        h.ok(
            total(count.fg) < total(count.bg) / 3,
            'the count text is not dark: ' .. vim.inspect(channels(count.fg))
        )
        local fg, bg = channels(label.fg), channels(label.bg)
        h.ok(fg[2] > fg[1] and fg[2] > fg[3], 'the label text is not green: ' .. vim.inspect(fg))
        h.ok(
            bg[2] >= bg[1] and bg[2] >= bg[3] and bg[2] > 200,
            'the label is not a light green: ' .. vim.inspect(bg)
        )
        h.ok(total(label.bg) > total(label.fg), 'the label is not lighter than its text')
        -- An end only has a foreground, so the cell behind it stays the window's and it looks round.
        h.eq({ left.fg, left.bg, right.fg, right.bg }, { count.bg, nil, label.bg, nil })
    end
)

test('below the total the header shows how far all the tasks have got, centered', function()
    local plugins = {}
    for _, name in ipairs({ 'a', 'b', 'c' }) do
        table.insert(plugins, { name = name, tasks = { h.lua('rtp', h.noop), h.lua('load', h.noop) } })
    end
    h.register(plugins)
    h.run({ plugins[1], plugins[2] })
    with_size(200, 50, function()
        ui.open()
        local got = header_all()
        h.eq(#got, 2)
        h.ok(got[1]:find('^ Total: 3 plugins%s+Sarcina$'), got[1])
        -- The name sits in the middle of the first line.
        local width = vim.api.nvim_win_get_config(ui._header_winid).width
        h.eq(
            vim.fn.strdisplaywidth(got[1]:sub(1, got[1]:find('Sarcina', 1, true) - 1)),
            math.floor((width - 7) / 2)
        )
        -- Loaded and not loaded on the left, the tasks in the middle.
        h.ok(got[2]:find('^ ● 2  ○ 1%s+4/6 tasks'), got[2])
        local at = got[2]:find('4/6 tasks', 1, true)
        h.eq(vim.fn.strdisplaywidth(got[2]:sub(1, at - 1)), math.floor((width - #'4/6 tasks') / 2))
        local ns = vim.api.nvim_get_namespaces().sarcina_window
        local marks = vim.api.nvim_buf_get_extmarks(
            ui._header_bufnr,
            ns,
            { 1, 0 },
            { 1, -1 },
            { details = true }
        )
        -- The run's own "4 done" sits at the end of the line, so only the counts and the tasks are compared.
        h.eq(vim.list_slice(vim.tbl_map(function(mark) return mark[4].hl_group end, marks), 1, 6), {
            'SarcinaDone',
            'SarcinaStepTime',
            'SarcinaPending',
            'SarcinaStepTime',
            'SarcinaStepTime',
            'SarcinaNote',
        })
    end)
end)

test('the footer names every key in its middle, and drops keys from the end when it is narrow', function()
    h.register({ loaded('a') })
    local function hint_text()
        local footer_text = vim.api.nvim_win_get_config(ui._footer_winid).footer
        return type(footer_text) == 'table' and footer_text[1][1] or footer_text
    end
    with_size(200, 50, function()
        ui.open()
        h.eq(vim.api.nvim_win_get_config(ui._footer_winid).footer_pos, 'center')
        h.eq(
            hint_text(),
            ' q close · = 50/50 · - taller · v select · ⏎ changelog · c/C check · u/U update · i install · l load · d delete · ^d/^u scroll '
        )
        vim.api.nvim_set_current_win(ui._winid)
        vim.api.nvim_feedkeys('v', 'xt', false)
        h.eq(hint_text(), ' v done · ␣ pick · c u i l d act on picks · q close · ^d/^u scroll ')
        vim.api.nvim_feedkeys('v', 'xt', false)
    end)
    with_size(100, 40, function()
        ui.open()
        local width = vim.api.nvim_win_get_config(ui._footer_winid).width
        h.ok(vim.fn.strdisplaywidth(hint_text()) <= width - 4, hint_text())
        h.ok(vim.startswith(hint_text(), ' q close · = 50/50 · - taller · v select'), hint_text())
        h.ok(not hint_text():find('scroll', 1, true), hint_text())
    end)
end)

test('the header counts what the session deleted', function()
    h.register({ loaded('a') })
    vim.fn.mkdir(paths.install('gone-a'), 'p')
    vim.fn.mkdir(paths.install('gone-b'), 'p')
    with_size(200, 50, function()
        ui.open()
        require('sarcina.installer').remove({ 'gone-a', 'gone-b' })
        h.ok(
            vim.wait(500, function() return header_all()[2]:find('^ ● %d+  ○ %d+  ✕ 2') end),
            header_all()[2]
        )
    end)
end)

test(
    'on a narrow header the work in progress drops the plugin name before it would run into Sarcina',
    function()
        local held = { name = 'slow', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
        h.register({ held })
        tasks.enqueue('slow', held)
        tasks.run_all()
        with_size(110, 40, function()
            h.ok(vim.wait(500, win_open), 'the window never opened')
            ui.open()
            local first = header_text()
            h.ok(first:find('Sarcina%s+⤓ Installing 0/1 plugin .-0%% $'), first)
            h.ok(not first:find('· slow', 1, true), first)
        end)
        release()
        h.ok(tasks.wait(2000))
    end
)

test('the total grows as the tasks of the plugins finish, up to all of them', function()
    local held = { name = 'a', tasks = { { id = 'install', type = 'w_hold' }, h.lua('rtp', h.noop) } }
    local fast = loaded('b')
    h.register({ held, fast })
    tasks.enqueue('a', held)
    tasks.enqueue('b', fast)
    tasks.run_all()
    with_size(200, 50, function()
        h.ok(vim.wait(500, win_open), 'the window never opened')
        -- b is done (1 of 1) and a is at its first task (1 of 2).
        h.ok(
            vim.wait(500, function() return header_all()[2]:find(' 2/3 tasks', 1, true) end),
            header_all()[2]
        )
        release()
        h.ok(tasks.wait(2000))
        h.ok(
            vim.wait(500, function() return header_all()[2]:find(' 3/3 tasks', 1, true) end),
            header_all()[2]
        )
    end)
end)

test('four windows are stacked and centered, 80% by 80% of the editor', function()
    h.register({ loaded('a'), loaded('b'), loaded('c') })
    with_size(120, 40, function()
        ui.open()
        local function config(win) return vim.api.nvim_win_get_config(win) end
        local header, list = config(ui._header_winid), config(ui._winid)
        local detail, bottom = config(ui._detail_winid), config(ui._footer_winid)
        -- 96 columns and 31 rows: a header of 4 rows, a footer of 3, and 24 for the panes with their borders.
        h.eq({ header.width + 2, bottom.width + 2, list.width + detail.width + 4 }, { 96, 96, 96 })
        h.eq({ header.height, bottom.height, list.height, detail.height }, { 2, 1, 22, 22 })
        h.eq(list.row, header.row + 4)
        h.eq(detail.row, list.row)
        h.eq(bottom.row, list.row + list.height + 2)
        h.eq(detail.col, list.col + list.width + 2)
        h.eq({ header.col, bottom.col }, { list.col, list.col })
        h.eq(bottom.row + bottom.height + 2 - header.row, 31)
        h.ok(math.abs(2 * header.col + 96 - 120) <= 1, 'not centered across')
        h.ok(math.abs(2 * header.row + 31 - 39) <= 1, 'not centered down')
        -- The main view gives the list 70% of the room the panes have, and the details the rest.
        h.eq({ list.width, detail.width }, { math.floor(92 * 0.7), 92 - math.floor(92 * 0.7) })
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
        h.eq({ list.width, list.height }, { 78, 22 })
        h.eq(#lines(), 60)
        h.ok(lines()[1]:find('…', 1, true), 'a long name was not cut: ' .. lines()[1])
        local before = { header_text(), footer(), vim.api.nvim_win_get_config(ui._header_winid).row }
        local footer_row = vim.api.nvim_win_get_config(ui._footer_winid).row
        h.eq(top_of(ui._winid), 1)
        vim.api.nvim_win_set_cursor(ui._winid, { #buffer_lines(), 0 })
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
            vim.wait(500, function() return lines()[1]:find('installing · Receiving', 1, true) end),
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
    local b = window.line('b') - 1 -- 0-based, as on_lines counts
    h.eq({ touched[b - 1], touched[b], touched[b + 1] }, { nil, true, nil })
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
            'tasks%s+.*2/2%s+tasks ✔.*%d+ms',
            'timing%s+trigger',
            'src%s+https://github%.com/owner/detailed',
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
        h.eq(detail_name(), 'detailed')
        h.eq({ vim.wo[ui._detail_winid].wrap, vim.wo[ui._detail_winid].breakindent }, { true, true })
    end)
end)

test('the details show the pin of a plugin, and no pin line for one without', function()
    local pinned =
        { name = 'pinned', repo = 'owner/pinned', version = '1.*', tasks = { h.lua('rtp', h.noop) } }
    local free = { name = 'free', repo = 'owner/free', tasks = { h.lua('rtp', h.noop) } }
    h.register({ pinned, free })
    h.run({ pinned, free })
    with_size(200, 50, function()
        ui.open()
        window.select(window.line('pinned'))
        window.draw_details(ui._detail_bufnr)
        local text = details_text()
        h.ok(text:find('pin%s+version 1%.%*'), text)
        local src, pin, path = text:find('\nsrc '), text:find('\npin '), text:find('\npath ')
        h.ok(src and pin and path and src < pin and pin < path, text)
        window.select(window.line('free'))
        window.draw_details(ui._detail_bufnr)
        h.ok(not details_text():find('pin%s'), details_text())
    end)
end)

-- The text of each highlighted piece of a line of the details, as { text = group }.
local function pieces(lnum)
    local ns = vim.api.nvim_get_namespaces().sarcina_details
    local line = vim.api.nvim_buf_get_lines(ui._detail_bufnr, lnum - 1, lnum, false)[1]
    local found = {}
    for _, mark in
        ipairs(
            vim.api.nvim_buf_get_extmarks(
                ui._detail_bufnr,
                ns,
                { lnum - 1, 0 },
                { lnum - 1, -1 },
                { details = true }
            )
        )
    do
        found[line:sub(mark[3] + 1, mark[4].end_col)] = mark[4].hl_group
    end
    return found
end

-- The line of the details that starts with `text`.
local function line_with(text)
    for lnum, line in ipairs(details()) do
        if vim.startswith(vim.trim(line), text) then return lnum end
    end
end

test('the tasks of a plugin that was installed before show installed, with the install time', function()
    local plugin = generated('oldwin.nvim', { repo = 'x/oldwin' })
    vim.fn.mkdir(paths.install('oldwin.nvim'), 'p')
    require('sarcina.installs').record('oldwin.nvim', 2314.5)
    h.register({ plugin })
    h.run({ { name = 'oldwin.nvim', tasks = { plugin.tasks[2] } } })
    with_size(200, 50, function()
        ui.open()
        h.ok(details_text():find('✔ install 2%.3s%s+installed'), details_text())
        h.ok(not details_text():find('not needed', 1, true), details_text())
    end)
end)

test('the details put a Tasks title above the tasks, and the time right after the task', function()
    local plugin = { name = 'titled', tasks = { h.lua('rtp', h.noop), { id = 'load', type = 'w_slow' } } }
    h.register({ plugin })
    h.run({ plugin })
    with_size(200, 50, function()
        ui.open()
        local got = details()
        local title = line_with('Tasks')
        h.ok(title, 'there is no Tasks title: ' .. details_text())
        h.eq(got[title - 1], '')
        h.ok(
            got[title + 1]:find('^ ✔ rtp [<%d%.]+ms'),
            'the time is not right after the task: ' .. got[title + 1]
        )
        h.ok(
            got[title + 2]:find('^ ✔ load %d+ms'),
            'the time is not right after the task: ' .. got[title + 2]
        )
        h.eq(pieces(title).Tasks, 'SarcinaHeader')
    end)
end)

test('each task has a highlight of its own, and its time stands out from it', function()
    local ids = {
        'install',
        'before',
        'build',
        'load_trigger',
        'rtp',
        'load',
        'keys',
        'after',
        'update',
        'check',
        'custom',
    }
    local steps = {}
    for _, id in ipairs(ids) do
        table.insert(steps, h.lua(id, h.noop))
    end
    h.register({ { name = 'colourful', tasks = steps } })
    h.run({ { name = 'colourful', tasks = steps } })
    local expected = {
        install = 'SarcinaStepInstall',
        before = 'SarcinaStepBefore',
        build = 'SarcinaStepBuild',
        load_trigger = 'SarcinaStepTrigger',
        rtp = 'SarcinaStepRtp',
        load = 'SarcinaStepLoad',
        keys = 'SarcinaStepKeys',
        after = 'SarcinaStepAfter',
        update = 'SarcinaStepUpdate',
        check = 'SarcinaStepCheck',
        custom = 'SarcinaStepOther',
    }
    with_size(200, 50, function()
        ui.open()
        local seen = {}
        for _, id in ipairs(ids) do
            local lnum = line_with('✔ ' .. id .. ' ')
            h.ok(lnum, id .. ' has no line: ' .. details_text())
            local marked = pieces(lnum)
            h.eq(marked[id], expected[id], id)
            seen[marked[id]] = true
            local time = details()[lnum]:match('%S+ ([<%d%.]+ms)')
            h.eq(marked[time], 'SarcinaStepTime', 'the time of ' .. id)
        end
        h.eq(vim.tbl_count(seen), #ids, 'two tasks share a highlight')
        h.eq(vim.api.nvim_get_hl(0, { name = 'SarcinaStepTime', link = false }).bold, true)
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
            vim.api.nvim_win_set_cursor(ui._winid, { window.line('b'), 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            h.eq(detail_name(), 'b')
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
        h.eq(detail_name(), 'a')
        for _, name in ipairs({ 'b', 'c', 'a' }) do
            vim.api.nvim_win_set_cursor(ui._winid, { window.line(name), 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            h.eq(detail_name(), name)
        end
        -- A section header names no plugin, so the details stay on the last one.
        vim.api.nvim_win_set_cursor(ui._winid, { 1, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
        h.eq(detail_name(), 'a')
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
                        and detail_name() == 'b'
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
            h.eq(detail_name(), 'a')
            release()
            h.ok(tasks.wait(2000))
            -- b loaded and moved above a; the cursor went with a.
            h.ok(
                vim.wait(500, function() return window.line('a') > window.line('b') end),
                'the rows did not move'
            )
            h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], window.line('a'))
            h.eq(detail_name(), 'a')
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

test(
    'the cursor rests only on rows of plugins, going on the way it moved off the blank lines at the ends',
    function()
        h.register({ { name = 'n1', timing = 'now' }, loaded('l1'), loaded('l2') })
        vim.o.columns, vim.o.lines = 200, 50
        ui.open()
        vim.api.nvim_set_current_win(ui._winid)
        -- 1 blank, 2 n1, 3 l1, 4 l2, 5 blank
        local function move(lnum)
            vim.api.nvim_win_set_cursor(ui._winid, { lnum, 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            return vim.api.nvim_win_get_cursor(ui._winid)[1], window.selected()
        end
        h.eq({ move(2) }, { 2, 'n1' })
        h.eq({ move(3) }, { 3, 'l1' })
        h.eq({ move(4) }, { 4, 'l2' })
        h.eq({ move(5) }, { 4, 'l2' }) -- nothing below the last plugin: back to it
        h.eq({ move(1) }, { 2, 'n1' }) -- nothing above the first plugin: the first plugin below it
        h.eq(detail_name(), 'n1')
    end
)

test('a line with no plugin shows no details', function()
    h.register({ loaded('a') })
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    window.select(1) -- the blank line at the top
    h.eq(window.selected(), nil)
    h.eq(window.draw_details(ui._detail_bufnr), nil)
    h.eq(details(), { '' })
    window.select(2)
    h.eq(window.draw_details(ui._detail_bufnr), 'a')
    -- A blank line above the name of the plugin, one under it, and one below the details.
    local shown = details()
    h.eq({ shown[1], vim.trim(shown[2]), shown[3], shown[4]:find('^state') ~= nil, shown[#shown] }, {
        '',
        'a',
        '',
        true,
        '',
    })
end)

test('entry_at maps the lines of the list to their plugins', function()
    h.register({ loaded('a'), loaded('b') })
    ui.open()
    h.eq(window.entry_at(1), { kind = 'blank' })
    h.eq(window.entry_at(2), { kind = 'plugin', name = 'a' })
    h.eq(window.entry_at(3), { kind = 'plugin', name = 'b' })
    h.eq(window.entry_at(4), { kind = 'blank' })
    h.eq(window.entry_at(5), nil)
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
        -- At 80 columns the state word gives way, and the glyph and the check say it.
        h.ok(vim.wait(500, function() return lines()[1]:find('tasks ✔', 1, true) end), lines()[1])
        h.ok(lines()[1]:find('^   clonewin.nvim%s+.*later%s+.*2/2%s+tasks ✔'), lines()[1])
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
        -- The child reads every spec file there, so it gets only this one, whatever other tests left behind.
        for _, other in ipairs(vim.fn.glob(specs .. '/*.lua', false, true)) do
            vim.fn.delete(other)
        end
        local file = specs .. '/window_child.lua'
        vim.fn.writefile({ 'return {', spec, '}' }, file)
        local script = vim.fn.tempname() .. '.lua'
        vim.fn.writefile({
            string.format('vim.opt.rtp:prepend(%q)', root),
            "require('sarcina').setup()",
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
        local row =
            vim.tbl_filter(function(line) return line:find('winchild.nvim', 1, true) end, seen.lines)[1]
        h.ok(row and row:find('^   winchild.nvim%s+.*later%s+.*3/3%s+tasks ✔'), vim.inspect(seen.lines))
    end)

    test('in a real startup with everything installed no window opens', function()
        vim.fn.mkdir(paths.install('winwarm.nvim'), 'p')
        local seen = run_child("    { name = 'winwarm.nvim', repo = 'x/winwarm', config = function() end },")
        h.eq(seen.open, false)
    end)
end

test(
    'the list keys send check, update, install, load and delete to the plugins under the cursor or selection',
    function()
        local plugins = {}
        for _, name in ipairs({ 'ka', 'kb', 'kc' }) do
            table.insert(plugins, { name = name, tasks = { h.lua('rtp', h.noop) } })
        end
        h.register(plugins)
        h.run(plugins)
        local cli = require('sarcina.cli')
        local dispatch, sent = cli.dispatch, {}
        cli.dispatch = function(args) table.insert(sent, args.fargs) end
        with_size(200, 50, function()
            ui.open()
            vim.api.nvim_set_current_win(ui._winid)
            local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false) end
            vim.api.nvim_win_set_cursor(ui._winid, { window.line('kb'), 0 })
            press('u')
            press('U')
            press('l')
            press('Vjd')
        end)
        cli.dispatch = dispatch
        h.eq(sent, { { 'update', 'kb' }, { 'update' }, { 'load', 'kb' }, { 'delete', 'kb', 'kc' } })
    end
)

test(
    'v opens the select view, Space picks, the footer names the picks, and v leaves and drops them',
    function()
        local plugins = {}
        for _, name in ipairs({ 'sa', 'sb', 'sc' }) do
            table.insert(plugins, { name = name, tasks = { h.lua('rtp', h.noop) } })
        end
        h.register(plugins)
        h.run(plugins)
        with_size(200, 50, function()
            ui.open()
            vim.api.nvim_set_current_win(ui._winid)
            local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false) end
            local function row(name)
                for _, line in ipairs(lines()) do
                    if line:find(name, 1, true) then return line end
                end
            end
            press('<Space>') -- outside the select view it does nothing
            h.eq(window.marked(), {})
            press('v')
            h.ok(row('sa'):find('^ ○ sa'), row('sa'))
            h.ok(footer()[1]:find('Space picks a plugin', 1, true), footer()[1])
            vim.api.nvim_win_set_cursor(ui._winid, { window.line('sa'), 0 })
            press('<Space>')
            vim.api.nvim_win_set_cursor(ui._winid, { window.line('sc'), 0 })
            press('<Space>')
            h.eq(window.marked(), { 'sa', 'sc' })
            h.ok(row('sa'):find('^ ✔ sa'), row('sa'))
            h.ok(row('sb'):find('^ ○ sb'), row('sb'))
            h.ok(footer()[1]:find('Selected 2', 1, true) and footer()[1]:find(' sa ', 1, true), footer()[1])
            press('<Space>') -- on a picked row it drops the pick
            h.eq(window.marked(), { 'sa' })
            press('v')
            h.eq(window.marked(), {})
            h.ok(row('sa'):find('^   sa'), row('sa'))
            h.ok(vim.startswith(footer()[1], ' v to select plugins'), footer()[1])
        end)
    end
)

test('the action keys act on the picks of the select view, and leave it', function()
    local plugins = {}
    for _, name in ipairs({ 'pa', 'pb', 'pc' }) do
        table.insert(plugins, { name = name, tasks = { h.lua('rtp', h.noop) } })
    end
    h.register(plugins)
    h.run(plugins)
    local cli = require('sarcina.cli')
    local dispatch, sent = cli.dispatch, {}
    cli.dispatch = function(args) table.insert(sent, args.fargs) end
    with_size(200, 50, function()
        ui.open()
        vim.api.nvim_set_current_win(ui._winid)
        local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false) end
        press('v')
        for _, name in ipairs({ 'pa', 'pc' }) do
            vim.api.nvim_win_set_cursor(ui._winid, { window.line(name), 0 })
            press('<Space>')
        end
        vim.api.nvim_win_set_cursor(ui._winid, { window.line('pb'), 0 })
        press('u')
        h.eq(window.select_mode, false)
        h.eq(window.marked(), {})
    end)
    cli.dispatch = dispatch
    h.eq(sent, { { 'update', 'pa', 'pc' } })
end)

test('a message shows in the right of the header, opens the window, and is never a notification', function()
    h.register({ loaded('a') })
    with_size(200, 50, function()
        ui.emit('warn', 'Not installed: ghost.nvim')
        h.ok(vim.wait(500, function() return ui._header_winid ~= nil end), 'the window did not open')
        local function second() return header_all()[2] end
        h.ok(
            vim.wait(500, function() return second():find('! Not installed: ghost.nvim', 1, true) end),
            second()
        )
        ui.emit('info', 'Everything is up to date')
        h.ok(
            vim.wait(500, function() return second():find('› Everything is up to date', 1, true) end),
            second()
        )
    end)
    h.eq(h.stray, {})
    h.ok(h.notified('Not installed: ghost.nvim'))
end)

test(
    'a question is asked in the header, y answers yes, n and Esc answer no, and nothing is a prompt',
    function()
        h.register({ loaded('a') })
        local confirm = require('sarcina.confirm')
        confirm.enabled = true
        local function ask_and_press(key)
            local answer
            confirm.ask(
                'Delete 1 plugin: a?\nStill in your specs, so it installs again at the next startup: a',
                function(yes) answer = yes end
            )
            h.ok(vim.wait(500, function() return ui._header_winid ~= nil end))
            h.eq(vim.api.nvim_get_current_win(), ui._winid)
            h.ok(header_all()[1]:find('? Delete 1 plugin: a?', 1, true), header_all()[1])
            h.ok(header_all()[2]:find('[y] yes  [n] no', 1, true), header_all()[2])
            vim.api.nvim_feedkeys(vim.keycode(key), 'xt', false)
            return answer
        end
        with_size(200, 50, function()
            h.eq(ask_and_press('y'), true)
            h.eq(ask_and_press('n'), false)
            h.eq(ask_and_press('<Esc>'), false)
            h.eq(ui._question, nil)
            h.ok(not header_all()[2]:find('[y] yes', 1, true), header_all()[2])
        end)
        confirm.enabled = false
        h.eq(h.stray, {})
    end
)

test('closing the window answers a waiting question with no', function()
    h.register({ loaded('a') })
    local confirm = require('sarcina.confirm')
    confirm.enabled = true
    local answer
    with_size(200, 50, function()
        confirm.ask('Update 1 plugin?', function(yes) answer = yes end)
        h.ok(vim.wait(500, function() return ui._winid ~= nil end))
        ui.close()
        h.ok(vim.wait(500, function() return answer ~= nil end), 'the question was left open')
    end)
    h.eq(answer, false)
    confirm.enabled = false
end)

test('the list moves up and down only: sideways keys do nothing, and a click lands in column 0', function()
    local plugins = {}
    for _, name in ipairs({ 'ha', 'hb' }) do
        table.insert(plugins, { name = name, tasks = { h.lua('rtp', h.noop) } })
    end
    h.register(plugins)
    h.run(plugins)
    with_size(200, 50, function()
        ui.open()
        vim.api.nvim_set_current_win(ui._winid)
        local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false) end
        vim.api.nvim_win_set_cursor(ui._winid, { window.line('ha'), 0 })
        for _, key in ipairs({ 'h', '$', 'w', '<Right>', 'fa', 'tb', 'e', '0' }) do
            press(key)
            h.eq(vim.api.nvim_win_get_cursor(ui._winid), { window.line('ha'), 0 }, key)
        end
        vim.api.nvim_win_set_cursor(ui._winid, { window.line('ha'), 9 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
        h.eq(vim.api.nvim_win_get_cursor(ui._winid)[2], 0)
        press('j')
        h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], window.line('hb'))
    end)
end)

test('the list buffer cannot be edited by hand: it is not modifiable, and editing keys do nothing', function()
    h.register({ { name = 'ea', tasks = { h.lua('rtp', h.noop) } } })
    with_size(200, 50, function()
        ui.open()
        vim.api.nvim_set_current_win(ui._winid)
        h.eq(vim.bo[ui._bufnr].modifiable, false)
        h.eq(vim.bo[ui._header_bufnr].modifiable, false)
        h.eq(vim.bo[ui._footer_bufnr].modifiable, false)
        local before = vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false)
        for _, key in ipairs({ 'x', 'o', 'p', 'J', 'D', 'r' }) do
            vim.api.nvim_feedkeys(vim.keycode(key .. 'z'), 'xt', false)
        end
        h.eq(vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false), before)
    end)
end)

test('a long list scrolled away and back shows its blank line at the top, and at the bottom', function()
    local plugins = {}
    for i = 1, 60 do
        table.insert(plugins, { name = 'long' .. i, tasks = { h.lua('rtp', h.noop) } })
    end
    h.register(plugins)
    h.run(plugins)
    with_size(200, 50, function()
        ui.open()
        vim.api.nvim_set_current_win(ui._winid)
        local function press(keys, times)
            for _ = 1, times or 1 do
                vim.api.nvim_feedkeys(keys, 'xt', false)
                vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            end
        end
        local function topline() return vim.api.nvim_win_call(ui._winid, vim.fn.winsaveview).topline end
        local count = vim.api.nvim_buf_line_count(ui._bufnr)
        h.ok(count > vim.api.nvim_win_get_height(ui._winid), 'the list fits the window')
        press('G')
        press('k', count)
        h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], window.line('long1'))
        h.eq(topline(), 1)
        press('j', count)
        h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], window.line('long60'))
        h.eq(topline(), count - vim.api.nvim_win_get_height(ui._winid) + 1)
        h.eq(buffer_lines()[count], '')
    end)
end)

test('a plugin on disk no spec owns is listed last as disabled, and goes when deleted', function()
    local plugins = { loaded('a'), vim.tbl_extend('force', loaded('b'), { timing = 'now' }) }
    h.register(plugins)
    h.run(plugins)
    vim.fn.mkdir(paths.install('gone'), 'p')
    require('sarcina.stats').disable({ 'gone' })
    with_size(200, 50, function()
        ui.open()
        local got = lines()
        h.eq(#got, 3)
        h.ok(got[1]:find('^   b%s'), got[1])
        h.eq(vim.trim(got[3]), 'gone disabled · not in your specs')
        -- The header counts the plugins of your specs only.
        h.ok(header_text():find('Total: 2 plugins', 1, true), header_text())
        h.ok(header_all()[2]:find('^ ● 2  ○ 0'), header_all()[2])
        vim.api.nvim_win_set_cursor(ui._winid, { window.line('gone'), 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
        local text = details_text()
        h.ok(text:find('state%s+− disabled'), text)
        h.ok(text:find('detail%s+not in your specs'), text)
        h.ok(not text:find('Tasks', 1, true), text)
        h.ok(not text:find('\ntasks%s'), text)
        require('sarcina.installer').remove({ 'gone' })
        h.ok(vim.wait(500, function() return #lines() == 2 end), vim.inspect(lines()))
    end)
end)

return tests
