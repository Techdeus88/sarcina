local h = require('helpers')
local load = require('sarcina.load')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function settle() h.ok(vim.wait(2000, load.idle, 5), 'later queue did not drain') end

test('now runs inline and reports whether it succeeded', function()
    local ran = false
    h.eq(load.now(function() ran = true end), true)
    h.eq(ran, true)
end)

test('now reports an error with its traceback and goes on', function()
    h.eq(load.now(function() error('boom') end), false)
    h.ok(h.notified('boom'))
    h.eq(load.now(h.noop), true)
end)

test('later waits, and runs in the order received, one callback per tick', function()
    local log = {}
    load.later(function() table.insert(log, 'a') end)
    load.later(function() table.insert(log, 'b') end)
    vim.schedule(function() table.insert(log, 'tick') end)
    h.eq(log, {})
    settle()
    h.eq(log, { 'a', 'tick', 'b' })
end)

test('a failing later callback does not stop the ones after it', function()
    local ran = false
    load.later(function() error('later broke') end)
    load.later(function() ran = true end)
    settle()
    h.eq(ran, true)
    h.ok(h.notified('later broke'))
end)

test('now_if_args runs now with file arguments and later without', function()
    local log = {}
    local argc = vim.fn.argc
    vim.fn.argc = function() return 2 end
    load.now_if_args(function() table.insert(log, 'with args') end)
    vim.fn.argc = function() return 0 end
    load.now_if_args(function() table.insert(log, 'no args') end)
    vim.fn.argc = argc
    h.eq(log, { 'with args' })
    settle()
    h.eq(log, { 'with args', 'no args' })
end)

test('nothing is reported, and no later callback runs, before startup is over', function()
    load._reset(false)
    local ran = false
    load.later(function() ran = true end)
    load.now(function() error('too early') end)
    vim.wait(50)
    h.eq(ran, false)
    h.eq(h.notified('too early'), false)
    load._open()
    settle()
    h.eq(ran, true)
    h.ok(h.notified('too early'))
end)

test('an event runs the callback once, with its pattern', function()
    local count = 0
    load.safely('event:User SarcinaLoadTest', function() count = count + 1 end)
    vim.cmd('doautocmd User SarcinaOther')
    h.eq(count, 0)
    vim.cmd('doautocmd User SarcinaLoadTest')
    vim.cmd('doautocmd User SarcinaLoadTest')
    h.eq(count, 1)
end)

test('a filetype runs the callback once', function()
    local count = 0
    load.safely('filetype:sarcinaft', function() count = count + 1 end)
    vim.cmd('new')
    vim.bo.filetype = 'sarcinaft'
    vim.bo.filetype = 'sarcinaft'
    vim.cmd('bwipeout!')
    h.eq(count, 1)
end)

test('an unknown load time is reported', function()
    load.safely('sometime', h.noop)
    h.ok(h.notified('Unknown load time: sometime'))
end)

return tests
