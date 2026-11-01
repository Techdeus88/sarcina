local h = require('helpers')
local tasks = require('sarcina.tasks')
local executors = require('sarcina.executors')
local ui = require('sarcina.ui')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

executors.t_slow = function(_, done)
    vim.defer_fn(function() done(true) end, 150)
end

executors.t_quiet = function(_, done)
    vim.defer_fn(function() done(true) end, 600)
end

executors.t_chatty = function(_, done, report)
    local output = { 'short', string.rep('x', 200), string.rep('y', 90), 'tiny', string.rep('z', 41) }
    local i = 0
    local function step()
        i = i + 1
        if i > #output then return done(true) end
        report(output[i])
        vim.defer_fn(step, 60)
    end
    step()
end

local function append_run(plugins)
    for _, plugin in ipairs(plugins) do
        tasks.enqueue(plugin.name, plugin, { append = true })
    end
    tasks.run_all(nil, { quiet = true, append = true })
    h.ok(tasks.wait(2000))
end

local function win_open() return ui._winid ~= nil and vim.api.nvim_win_is_valid(ui._winid) end

local function lines() return vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false) end

local function title()
    local text = vim.api.nvim_win_get_config(ui._winid).title
    if type(text) == 'table' then
        text = table.concat(
            vim.tbl_map(function(chunk) return type(chunk) == 'table' and chunk[1] or chunk end, text)
        )
    end
    return text
end

local function failing(name)
    return {
        name = name,
        tasks = {
            h.lua('x', function() error('no') end),
        },
    }
end

test('rows keep enqueue order and failures get their own glyph', function()
    local plugins = {}
    for i = 1, 6 do
        local fn = i == 3 and function() error('boom') end or h.noop
        table.insert(plugins, { name = 'plugin' .. i, tasks = { h.lua('load', fn) } })
    end
    h.run(plugins)
    ui.open()
    local got = lines()
    h.eq(#got, 6)
    for i = 1, 6 do
        h.ok(got[i]:find('plugin' .. i, 1, true), 'row ' .. i .. ' is ' .. got[i])
    end
    h.ok(vim.startswith(got[1], '✔'))
    h.ok(vim.startswith(got[3], '✘'))
    h.ok(got[3]:find('error: ', 1, true))
end)

test('the panel shows a job as running while it runs', function()
    ui.show_delay = 0
    tasks.enqueue('slow', { tasks = { { id = 'a', type = 't_slow' } } })
    tasks.run_all()
    h.ok(vim.wait(100, win_open), 'panel never opened')
    h.ok(vim.startswith(lines()[1], '▶'), lines()[1])
    h.ok(tasks.wait(2000))
    h.ok(vim.wait(200, function() return vim.startswith(lines()[1], '✔') end))
end)

test('the title counts finished jobs and failures', function()
    h.run({ failing('a'), { name = 'b', tasks = { h.lua('y', h.noop), h.lua('z', h.noop) } } })
    ui.open()
    h.eq(title(), ' Sarcina 3/3 · 1 failed ')
end)

test('a failure opens the panel on its own', function()
    h.run({ failing('a') })
    h.ok(vim.wait(200, win_open))
end)

test('the panel opens when show_delay passes, even if no task reports anything', function()
    tasks.enqueue('quiet', { tasks = { { id = 'a', type = 't_quiet' } } })
    tasks.run_all()
    h.ok(vim.wait(450, win_open), 'panel never opened while the task stayed silent')
    h.ok(tasks.wait(2000))
end)

test('the panel keeps its height while a running job reports lines of any length', function()
    ui.show_delay = 0
    tasks.enqueue('chatty', { tasks = { { id = 'a', type = 't_chatty' } } })
    tasks.run_all()
    h.ok(vim.wait(500, win_open), 'panel never opened')
    local heights, widest = {}, 0
    vim.wait(450, function()
        if win_open() then
            heights[vim.api.nvim_win_get_config(ui._winid).height] = true
            for _, line in ipairs(lines()) do
                widest = math.max(widest, vim.fn.strdisplaywidth(line))
            end
        end
        return false
    end, 10)
    h.eq(vim.tbl_count(heights), 1, 'heights seen: ' .. vim.inspect(vim.tbl_keys(heights)))
    h.ok(
        widest <= vim.api.nvim_win_get_config(ui._winid).width,
        'a running row spilled past the window width'
    )
    h.ok(tasks.wait(2000))
end)

test('an appended run keeps earlier failures in the panel', function()
    h.run({ failing('a') })
    h.ok(vim.wait(200, win_open))
    append_run({ { name = 'b', tasks = { h.lua('y', h.noop) } } })
    vim.wait(100)
    local text = table.concat(lines(), '\n')
    h.ok(text:find('✘ a – x', 1, true), text)
    h.ok(text:find('✔ b – y', 1, true), text)
end)

test('with nothing running the cursor sits on the newest failure', function()
    h.run({ failing('a'), { name = 'b', tasks = { h.lua('y', h.noop) } }, failing('c') })
    ui.open()
    h.eq(vim.api.nvim_win_get_cursor(ui._winid)[1], 3)
end)

test('a clean appended run does not auto-close a panel that still shows a failure', function()
    ui.close_delay = 50
    h.run({ failing('a') })
    h.ok(vim.wait(200, win_open))
    append_run({ { name = 'b', tasks = { h.lua('y', h.noop) } } })
    vim.wait(300)
    h.ok(win_open(), 'the panel closed on top of an unseen failure')
end)

test('a dismissed panel ignores a clean appended run but reopens for a new failure', function()
    h.run({ failing('a') })
    h.ok(vim.wait(200, win_open))
    ui.dismiss()
    append_run({ { name = 'b', tasks = { h.lua('y', h.noop) } } })
    vim.wait(300)
    h.eq(win_open(), false)
    append_run({ failing('c') })
    h.ok(vim.wait(300, win_open), 'a new failure did not reopen the panel')
    h.ok(title():find('2 failed', 1, true), title())
end)

test('a normal run toasts one summary line', function()
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop) } } })
    h.eq(#h.notes, 1)
    h.eq(h.notes[1].msg, '[Sarcina] 1 done')
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

test('a quick clean run never opens the panel', function()
    h.run({ { name = 'p', tasks = { h.lua('a', h.noop) } } })
    vim.wait(400)
    h.eq(ui._winid, nil)
end)

test('closing the window dismisses the panel until the next run', function()
    h.run({ failing('p') })
    h.ok(vim.wait(200, win_open))
    vim.api.nvim_win_close(ui._winid, true)
    h.eq(ui._dismissed, true)
    h.run({ failing('p') })
    h.ok(vim.wait(200, win_open), 'panel did not come back for the new run')
end)

test('q dismisses the panel', function()
    h.run({ failing('p') })
    h.ok(vim.wait(200, win_open))
    local map = vim.api.nvim_buf_call(ui._bufnr, function() return vim.fn.maparg('q', 'n', false, true) end)
    h.eq(map.buffer, 1)
    map.callback()
    h.eq(win_open(), false)
    h.eq(ui._dismissed, true)
end)

test('a clean run closes the panel after close_delay', function()
    ui.show_delay = 0
    ui.close_delay = 50
    tasks.enqueue('slow', { tasks = { { id = 'a', type = 't_slow' } } })
    tasks.run_all()
    h.ok(vim.wait(100, win_open))
    h.ok(tasks.wait(2000))
    h.ok(vim.wait(500, function() return not win_open() end))
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
    h.eq(last.msg, '[Sarcina] 0 done, 1 failed')
    h.eq(last.level, vim.log.levels.ERROR)
end)

return tests
