local h = require('helpers')
local executors = require('sarcina.executors')
local tasks = require('sarcina.tasks')
local ui = require('sarcina.ui')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

-- A task that does real work: it says so and takes 150 ms.
executors.t_work = function(job, done, report)
    job.working = true
    report()
    vim.defer_fn(function() done(true) end, 150)
end

-- A long task that never says it is working.
executors.t_quiet = function(_, done)
    vim.defer_fn(function() done(true) end, 600)
end

executors.t_chatty = function(job, done, report)
    local output = { 'short', string.rep('x', 200), string.rep('y', 90), 'tiny', string.rep('z', 41) }
    local i = 0
    job.working = true
    local function step()
        i = i + 1
        if i > #output then return done(true) end
        report(output[i])
        vim.defer_fn(step, 60)
    end
    step()
end

local function run(plugins, opts)
    h.register(plugins)
    return h.run(plugins, opts)
end

local function append_run(plugins)
    h.register(plugins, true)
    for _, plugin in ipairs(plugins) do
        tasks.enqueue(plugin.name, plugin, { append = true })
    end
    tasks.run_all(nil, { quiet = true, append = true })
    h.ok(tasks.wait(2000))
end

local function win_open() return ui._winid ~= nil and vim.api.nvim_win_is_valid(ui._winid) end

local function lines() return vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false) end

local function header() return vim.api.nvim_buf_get_lines(ui._header_bufnr, 0, -1, false)[1] end

local function loaded(name) return { name = name, tasks = { h.lua('rtp', h.noop) } } end

local function failing(name)
    return { name = name, tasks = { h.lua('x', function() error('no') end) } }
end

local function working(name) return { name = name, tasks = { { id = 'a', type = 't_work' } } } end

-- Real work that is over at once, so a test can finish a run without waiting on a timer of its own.
executors.t_work_now = function(job, done)
    job.working = true
    done(true)
end

local function work_now(name) return { name = name, tasks = { { id = 'a', type = 't_work_now' } } } end

-- Collects the vim.defer_fn callbacks scheduled while `body` runs. `elapse()` runs them all, and the ones they
-- schedule, as if all the time had passed.
local function with_timers(body)
    local real, timers = vim.defer_fn, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.defer_fn = function(fn) table.insert(timers, fn) end
    local ok, err = pcall(body, function()
        local i = 1
        while timers[i] do
            timers[i]()
            i = i + 1
        end
    end)
    vim.defer_fn = real
    assert(ok, err)
end

test('a failure opens the window on its own', function()
    run({ failing('a') })
    h.ok(vim.wait(200, win_open))
end)

test('a task that does real work opens the window', function()
    h.register({ working('w') })
    tasks.enqueue('w', working('w'))
    tasks.run_all()
    h.ok(vim.wait(200, win_open), 'the window never opened')
    h.ok(tasks.wait(2000))
end)

test('a long task that never says it works does not open the window', function()
    h.register({ { name = 'q', tasks = { { id = 'a', type = 't_quiet' } } } })
    tasks.enqueue('q', { tasks = { { id = 'a', type = 't_quiet' } } })
    tasks.run_all()
    vim.wait(450)
    h.eq(win_open(), false)
    h.ok(tasks.wait(2000))
end)

test('the window keeps its size while a running job reports lines of any length', function()
    h.register({ { name = 'chatty', tasks = { { id = 'a', type = 't_chatty' } } } })
    tasks.enqueue('chatty', { tasks = { { id = 'a', type = 't_chatty' } } })
    tasks.run_all()
    h.ok(vim.wait(500, win_open), 'the window never opened')
    local sizes, widest = {}, 0
    vim.wait(450, function()
        if win_open() then
            local config = vim.api.nvim_win_get_config(ui._winid)
            sizes[config.width .. 'x' .. config.height] = true
            for _, line in ipairs(lines()) do
                widest = math.max(widest, vim.fn.strdisplaywidth(line))
            end
        end
        return false
    end, 10)
    h.eq(vim.tbl_count(sizes), 1, 'sizes seen: ' .. vim.inspect(vim.tbl_keys(sizes)))
    h.ok(widest <= vim.api.nvim_win_get_config(ui._winid).width, 'a row spilled past the window width')
    h.ok(tasks.wait(2000))
end)

test('an appended run keeps earlier failures in the window', function()
    run({ failing('a') })
    h.ok(vim.wait(200, win_open))
    append_run({ loaded('b') })
    vim.wait(100)
    local function row_of(name)
        for _, line in ipairs(lines()) do
            if line:find('^%s+' .. name .. '%s') then return line end
        end
    end
    h.ok(row_of('a'):find('later.*1/1%s+tasks ✘'), row_of('a'))
    h.ok(row_of('b'):find('later.*1/1%s+tasks ✔'), row_of('b'))
end)

test('the cursor sits on the plugin at work, else on the last failed one', function()
    run({ failing('a'), loaded('b'), failing('c') })
    ui.open()
    h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], require('sarcina.window').line('c'))
end)

test('a clean appended run leaves a window that still shows a failure open', function()
    run({ failing('a') })
    h.ok(vim.wait(200, win_open))
    append_run({ loaded('b') })
    vim.wait(300)
    h.ok(win_open(), 'the window closed on top of an unseen failure')
end)

test('a dismissed window ignores a clean appended run but reopens for a new failure', function()
    run({ failing('a') })
    h.ok(vim.wait(200, win_open))
    ui.dismiss()
    append_run({ loaded('b') })
    vim.wait(300)
    h.eq(win_open(), false)
    append_run({ failing('c') })
    h.ok(vim.wait(300, win_open), 'a new failure did not reopen the window')
    h.ok(header():find('^ Total: 3 plugins%s+Sarcina'), header())
    local failed = 0
    for _, line in ipairs(lines()) do
        if line:find('✘', 1, true) then failed = failed + 1 end
    end
    h.eq(failed, 2)
end)

test('a normal run toasts one summary line', function()
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop) } } })
    h.eq(#h.notes, 1)
    h.eq(h.notes[1].msg, '1 task done')
end)

test('a quiet run toasts nothing when clean and one line when it fails', function()
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop) } } }, { quiet = true })
    h.eq(h.notes, {})
    h.run({ failing('q') }, { quiet = true })
    h.eq(#h.notes, 1)
    h.ok(h.notified('1 failed'))
end)

test('debug events reach listeners but never become toasts', function()
    local seen = {}
    ui.on('debug', function(text) table.insert(seen, text) end)
    ui.emit('debug', 'details')
    h.eq(seen, { 'details' })
    h.eq(h.notes, {})
end)

test('a quick clean run never opens the window', function()
    run({ loaded('p') })
    vim.wait(400)
    h.eq(ui._winid, nil)
end)

test('closing the window dismisses it until the next run', function()
    run({ failing('p') })
    h.ok(vim.wait(200, win_open))
    vim.api.nvim_win_close(ui._winid, true)
    h.eq(ui._dismissed, true)
    run({ failing('p') })
    h.ok(vim.wait(200, win_open), 'the window did not come back for the new run')
end)

test('q dismisses the window', function()
    run({ failing('p') })
    h.ok(vim.wait(200, win_open))
    local map = vim.api.nvim_buf_call(ui._bufnr, function() return vim.fn.maparg('q', 'n', false, true) end)
    h.eq(map.buffer, 1)
    map.callback()
    h.eq(win_open(), false)
    h.eq(ui._dismissed, true)
end)

test('no timer closes the window after a clean run', function()
    with_timers(function(elapse)
        h.register({ work_now('w') })
        tasks.enqueue('w', work_now('w'))
        tasks.run_all()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(200, win_open), 'the window never opened')
        elapse()
        vim.wait(50)
        h.ok(win_open(), 'a timer closed the window')
    end)
    ui.dismiss()
    h.eq(win_open(), false)
end)

test('a message that expires from the header leaves the window open', function()
    with_timers(function(elapse)
        ui.emit('info', 'hello')
        h.ok(vim.wait(200, win_open), 'a message did not open the window')
        elapse()
        vim.wait(50)
        h.eq(require('sarcina.window').message, nil)
        h.ok(win_open(), 'the window left with its message')
    end)
end)

test('a failure right after a clean run is not closed by the clean run', function()
    with_timers(function(elapse)
        h.register({ work_now('w') })
        tasks.enqueue('w', work_now('w'))
        tasks.run_all()
        h.ok(tasks.wait(2000))
        h.ok(vim.wait(200, win_open), 'the window never opened')
        run({ failing('f') })
        elapse()
        vim.wait(50)
        h.eq(tasks.snapshot().counts.failed, 1)
        h.ok(win_open(), 'the clean run closed the window on a failure')
    end)
end)

test('a window opened by hand stays after a clean run', function()
    run({ loaded('a') })
    ui.open()
    h.ok(win_open())
    append_run({ loaded('b') })
    vim.wait(300)
    h.ok(win_open(), 'the window closed under the user')
end)

test('opening by hand goes into the window and says so when there is nothing to show', function()
    ui.open()
    h.ok(h.notified('No task activity yet'))
    run({ loaded('a') })
    ui.open()
    h.eq(vim.api.nvim_get_current_win(), ui._winid)
end)

test('show = never keeps the window shut, even for a failure', function()
    ui.configure({ show = 'never' })
    run({ failing('a') })
    vim.wait(200)
    h.eq(win_open(), false)
end)

test('show = always opens the window when the startup run starts, even when it is clean', function()
    ui.configure({ show = 'always' })
    h.register({ loaded('a') })
    tasks.enqueue('a', loaded('a'))
    tasks.run_all(nil, { quiet = true })
    h.ok(vim.wait(200, win_open), 'the window did not open at the start of the run')
end)

test('real work waits for the colorscheme before it opens the window', function()
    ui.init()
    vim.g.colors_name = nil
    h.register({ working('w') })
    tasks.enqueue('w', working('w'))
    tasks.run_all()
    vim.wait(100)
    h.eq(win_open(), false)
    vim.cmd.colorscheme('default')
    h.ok(vim.wait(200, win_open), 'the window did not open once the colorscheme was applied')
    h.ok(tasks.wait(2000))
end)

test('a clone opens the window at once, without waiting for the colorscheme', function()
    ui.init()
    vim.g.colors_name = nil
    local clone = { name = 'c', tasks = { { id = 'install', type = 't_work' } } }
    h.register({ clone })
    tasks.enqueue('c', clone)
    tasks.run_all()
    h.ok(vim.wait(100, win_open), 'the window waited for a colorscheme during a clone')
    h.ok(tasks.wait(2000))
end)

test('with no colorscheme the window opens after theme_wait', function()
    vim.g.colors_name = nil
    ui.theme_wait = 150
    h.register({ working('w') })
    tasks.enqueue('w', working('w'))
    tasks.run_all()
    vim.wait(80)
    h.eq(win_open(), false)
    h.ok(vim.wait(300, win_open), 'the window never opened without a colorscheme')
    h.ok(tasks.wait(2000))
end)

test('a failure opens the window without waiting for the colorscheme', function()
    vim.g.colors_name = nil
    run({ failing('a') })
    h.ok(vim.wait(200, win_open))
end)

test('show falls back to auto for a value it does not know', function()
    ui.configure({ show = 'sometimes' })
    h.eq(ui.show, 'auto')
    h.ok(h.notified('Unknown ui.show sometimes'))
    ui.configure({ show = 'never' })
    h.eq(ui.show, 'never')
    ui.configure(nil)
    h.eq(ui.show, 'auto')
end)

test('warn and warning both notify', function()
    ui.emit('warn', 'a')
    ui.emit('warning', 'b')
    h.eq(#h.notes, 2)
    h.eq(h.notes[1].level, vim.log.levels.WARN)
    h.eq(h.notes[2].level, vim.log.levels.WARN)
end)

test('the end-of-run summary reports failures at error level', function()
    h.run({ failing('p') })
    local last = h.notes[#h.notes]
    h.eq(last.msg, '0 tasks done, 1 failed')
    h.eq(last.level, vim.log.levels.ERROR)
end)

test('every message and debug line goes to the log file, one line each', function()
    local log = require('sarcina.log')
    vim.fn.delete(log.path())
    log._reset()
    ui.emit('warn', 'Not installed: ghost.nvim')
    ui.emit('error', 'two\nlines')
    ui.emit('debug', 'derived a name')
    local got = vim.fn.readfile(log.path())
    h.eq(#got, 3)
    h.ok(got[1]:find('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d WARN  Not installed: ghost.nvim$'), got[1])
    h.ok(got[2]:find('ERROR two | lines$'), got[2])
    h.ok(got[3]:find('DEBUG derived a name$'), got[3])
    h.eq(h.stray, {})
end)

test(':Sarcina log opens the log file, and says so when there is none', function()
    local log = require('sarcina.log')
    vim.fn.delete(log.path())
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina log')
    h.ok(h.notified('The log is empty'), vim.inspect(h.notes))
    ui.emit('info', 'something happened')
    vim.cmd('Sarcina log')
    h.eq(vim.uv.fs_realpath(vim.fn.expand('%:p')), vim.uv.fs_realpath(log.path()))
    vim.cmd('close')
end)

local function backdrop_open()
    return ui._backdrop_winid ~= nil and vim.api.nvim_win_is_valid(ui._backdrop_winid)
end

test(
    'a window opened by hand has a backdrop over the editor, under the window, gone when it closes',
    function()
        run({ loaded('a') })
        ui.open()
        h.ok(backdrop_open(), 'no backdrop')
        local config = vim.api.nvim_win_get_config(ui._backdrop_winid)
        h.eq({ config.width, config.height, config.focusable }, { vim.o.columns, vim.o.lines, false })
        h.ok(config.zindex < vim.api.nvim_win_get_config(ui._winid).zindex, 'the backdrop is over the window')
        h.eq(vim.wo[ui._backdrop_winid].winblend, 50)
        vim.cmd('close')
        h.eq(backdrop_open(), false)
    end
)

test('a window that opens by itself has no backdrop until it is opened by hand', function()
    run({ failing('a') })
    h.ok(vim.wait(500, win_open))
    h.eq(backdrop_open(), false)
    ui.open()
    h.ok(backdrop_open(), 'opening by hand added no backdrop')
    ui.close()
    h.eq(backdrop_open(), false)
end)

test('backdrop takes a blend, false turns it off, and an unknown value warns', function()
    ui.configure({ backdrop = 60 })
    run({ loaded('a') })
    ui.open()
    h.eq(vim.wo[ui._backdrop_winid].winblend, 60)
    ui.close()
    ui.configure({ backdrop = false })
    ui.open()
    h.eq(backdrop_open(), false)
    ui.close()
    ui.configure({ backdrop = 'dim' })
    h.ok(h.notified('Unknown ui.backdrop dim, using 50'))
    h.eq(ui.backdrop, 50)
end)

test('the backdrop is half transparent unless setup says otherwise', function()
    ui.configure({ backdrop = 10 })
    h.eq(ui.backdrop, 10)
    ui.configure({})
    h.eq(ui.backdrop, 50)
    ui.configure({ backdrop = 0 })
    h.eq(ui.backdrop, 0)
end)

test('the backdrop follows the editor size', function()
    ui.init()
    run({ loaded('a') })
    ui.open()
    vim.o.columns, vim.o.lines = vim.o.columns + 10, vim.o.lines + 4
    vim.api.nvim_exec_autocmds('VimResized', {})
    h.ok(
        vim.wait(500, function()
            local config = vim.api.nvim_win_get_config(ui._backdrop_winid)
            return config.width == vim.o.columns and config.height == vim.o.lines
        end),
        'the backdrop kept its old size'
    )
end)

return tests
