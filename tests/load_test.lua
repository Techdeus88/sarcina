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

test('later waits, and runs in the order received', function()
    local log = {}
    load.later(function() table.insert(log, 'a') end)
    load.later(function() table.insert(log, 'b') end)
    vim.schedule(function() table.insert(log, 'tick') end)
    h.eq(log, {})
    settle()
    h.eq(log, { 'tick', 'a', 'b' })
end)

test('later gives the editor a turn between callbacks', function()
    local ticks, seen, done = 0, {}, 0
    local timer = vim.uv.new_timer()
    timer:start(0, 1, function() ticks = ticks + 1 end)
    for _ = 1, 6 do
        load.later(function()
            table.insert(seen, ticks)
            local start = vim.uv.hrtime()
            while (vim.uv.hrtime() - start) / 1e6 < 3 do
            end
            done = done + 1
        end)
    end
    settle()
    timer:stop()
    timer:close()
    h.eq(done, 6)
    h.ok(seen[#seen] - seen[1] >= 3, 'the loop never ran between the callbacks: ' .. table.concat(seen, ' '))
end)

test('callbacks queued before a reset never run', function()
    local log = {}
    load.later(function() table.insert(log, 'old') end)
    load._reset()
    load.later(function() table.insert(log, 'new') end)
    settle()
    h.eq(log, { 'new' })
end)

test('a later callback that fails names the place it was queued from', function()
    load.later(function() error('boom later') end)
    settle()
    h.ok(h.notified('boom later'))
    h.ok(h.notified('Queued from:'))
    h.ok(h.notified('load_test.lua'))
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
    load.safely('ft:sarcinaft', function() count = count + 1 end)
    vim.cmd('new')
    vim.bo.filetype = 'sarcinaft'
    vim.bo.filetype = 'sarcinaft'
    vim.cmd('bwipeout!')
    h.eq(count, 1)
end)

test('an event loader takes several events and runs once, whichever comes first', function()
    local count = 0
    load.safely('event:BufNew,BufAdd', function() count = count + 1 end)
    vim.cmd('enew!')
    vim.cmd('bwipeout!')
    vim.cmd('enew!')
    vim.cmd('bwipeout!')
    h.eq(count, 1)
end)

test('an event loader lets the events its callback causes run their handlers', function()
    local hits = 0
    local group = vim.api.nvim_create_augroup('load_nested_test', { clear = true })
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'LoadInner',
        callback = function() hits = hits + 1 end,
    })
    load.safely('event:User LoadOuter', function() vim.cmd('doautocmd User LoadInner') end)
    vim.cmd('doautocmd User LoadOuter')
    vim.api.nvim_del_augroup_by_name('load_nested_test')
    h.eq(hits, 1)
end)

test('an ft loader takes several filetypes and runs once', function()
    local count = 0
    load.safely('ft:loadone,loadtwo', function() count = count + 1 end)
    vim.cmd('new')
    vim.bo.filetype = 'loadtwo'
    vim.bo.filetype = 'loadone'
    vim.cmd('bwipeout!')
    h.eq(count, 1)
end)

test('an ft loader applies the ftplugin its callback brought to the buffer that woke it', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/ftplugin', 'p')
    vim.fn.writefile({ 'vim.b.ftplugin_ran = true' }, dir .. '/ftplugin/loadrefresh.lua')
    local detection = vim.fn.execute('filetype')
    vim.cmd('filetype plugin on')
    load.safely('ft:loadrefresh', function() vim.opt.rtp:append(dir) end)
    vim.cmd('new')
    vim.bo.filetype = 'loadrefresh'
    local ran = vim.b.ftplugin_ran
    vim.cmd('bwipeout!')
    vim.opt.rtp:remove(dir)
    if not detection:find('plugin:ON', 1, true) then vim.cmd('filetype plugin off') end
    h.eq(ran, true)
end)

test('a loader that cannot be set up reports it instead of raising', function()
    load.safely('event:NotAnEventAtAll', h.noop)
    h.ok(h.notified('Could not set up event:NotAnEventAtAll'))
end)

test('only event, ft, keys and cmd are loaders', function()
    load.safely('filetype:lua', h.noop)
    load.safely('key:<F5>', h.noop)
    h.ok(h.notified('Unknown load time: filetype:lua'))
    h.ok(h.notified('Unknown load time: key:<F5>'))
    h.eq(vim.fn.maparg('<F5>', 'n'), '')
end)

test(
    'an event loader repeats the autocmds its callback added, once, and then stays out of the way',
    function()
        local loads, hits = 0, 0
        load.safely('event:User SafelyEvent', function()
            loads = loads + 1
            vim.api.nvim_create_autocmd('User', {
                pattern = 'SafelyEvent',
                callback = function() hits = hits + 1 end,
            })
        end)
        vim.cmd('doautocmd User SafelyEvent')
        h.eq({ loads, hits }, { 1, 1 })
        vim.cmd('doautocmd User SafelyEvent')
        h.eq({ loads, hits }, { 1, 2 })
        vim.api.nvim_clear_autocmds({ event = 'User', pattern = 'SafelyEvent' })
    end
)

test('a command loader loads once, then repeats the command with its arguments and bang', function()
    local loads, calls = 0, {}
    load.safely('cmd:SafelyCmd', function()
        loads = loads + 1
        vim.api.nvim_create_user_command(
            'SafelyCmd',
            function(opts) table.insert(calls, { opts.args, opts.bang }) end,
            { nargs = '*', bang = true }
        )
    end)
    h.eq(vim.fn.exists(':SafelyCmd'), 2)
    vim.cmd('SafelyCmd! one two')
    vim.cmd('SafelyCmd again')
    h.eq(loads, 1)
    h.eq(calls, { { 'one two', true }, { 'again', false } })
    vim.api.nvim_del_user_command('SafelyCmd')
end)

test('a command loader repeats a range', function()
    local range
    load.safely('cmd:SafelyRange', function()
        vim.api.nvim_create_user_command(
            'SafelyRange',
            function(opts) range = { opts.line1, opts.line2 } end,
            { range = true }
        )
    end)
    vim.cmd('new')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c', 'd' })
    vim.cmd('2,3SafelyRange')
    vim.cmd('bwipeout!')
    h.eq(range, { 2, 3 })
    vim.api.nvim_del_user_command('SafelyRange')
end)

test('a command loader whose callback fails reports it and does not repeat the command', function()
    load.safely('cmd:SafelyBad', function() error('bad loader') end)
    vim.cmd('SafelyBad')
    h.ok(h.notified('bad loader'))
    h.eq(h.notified('E492'), false)
    h.eq(vim.fn.exists(':SafelyBad'), 0)
end)

test('a key loader loads once, then feeds the key again', function()
    local loads, hits = 0, 0
    load.safely('keys:<F6>', function()
        loads = loads + 1
        vim.keymap.set('n', '<F6>', function() hits = hits + 1 end)
    end)
    local stub = vim.fn.maparg('<F6>', 'n', false, true)
    h.eq(type(stub.callback), 'function')
    stub.callback()
    vim.api.nvim_feedkeys('', 'x', false)
    h.eq({ loads, hits }, { 1, 1 })
    pcall(vim.keymap.del, 'n', '<F6>')
end)

test('keys can name their modes first', function()
    load.safely('keys:nv <F7>', h.noop)
    h.eq(type(vim.fn.maparg('<F7>', 'n', false, true).callback), 'function')
    h.eq(type(vim.fn.maparg('<F7>', 'v', false, true).callback), 'function')
    h.eq(vim.fn.maparg('<F7>', 'i'), '')
    pcall(vim.keymap.del, { 'n', 'v' }, '<F7>')
end)

test('an unknown load time is reported', function()
    load.safely('sometime', h.noop)
    h.ok(h.notified('Unknown load time: sometime'))
end)

return tests
