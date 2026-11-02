local h = require('helpers')
local schema = require('sarcina.schema')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

test(':Sarcina dispatches subcommands', function()
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina help')
    h.ok(h.notified('Subcommands: add'))
    vim.cmd('Sarcina bogus')
    h.ok(h.notified('bogus'))
end)

test(':Sarcina stats prints the numbers on one line', function()
    vim.cmd('runtime plugin/sarcina.lua')
    require('sarcina.stats').register({
        { name = 'a', timing = 'now' },
        { name = 'b', timing = 'later' },
        { name = 'c', timing = 'trigger' },
    })
    require('sarcina.load')._reset(false)
    vim.cmd('Sarcina stats')
    h.ok(
        h.notified(
            '3 plugins · 0 loaded · 3 not loaded · 1 now · 1 later · 1 triggered · startup pending'
        )
    )
    local load = require('sarcina.load')
    load._open()
    h.ok(vim.wait(1000, load.idle, 5), 'the load gate did not settle')
    vim.cmd('Sarcina stats')
    h.ok(h.notified(' ms'))
end)

test(':Sarcina panel says so when there is nothing to show', function()
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina panel')
    h.ok(h.notified('No task activity yet'))
end)

test('completes subcommand names', function() h.eq(require('sarcina.cli').complete('pa'), { 'panel' }) end)

test('completes the new subcommands, and the names of the plugins after check and update', function()
    local cli = require('sarcina.cli')
    h.eq(
        { cli.complete('cl'), cli.complete('up'), cli.complete('ch') },
        { { 'clean' }, { 'update' }, { 'check' } }
    )
    require('sarcina.stats').register({
        { name = 'cmpone', timing = 'later' },
        { name = 'cmptwo', timing = 'later' },
    })
    h.eq(cli.complete('cmp', 'Sarcina update cmp'), { 'cmpone', 'cmptwo' })
    h.eq(cli.complete('cmpt', 'Sarcina check cmpt'), { 'cmptwo' })
    h.eq(cli.complete('cmp', 'Sarcina panel cmp'), {})
end)

test(':Sarcina takes a bang, and help lists clean, check and update', function()
    vim.cmd('runtime plugin/sarcina.lua')
    h.eq(vim.api.nvim_get_commands({}).Sarcina.bang, true)
    vim.cmd('Sarcina help')
    h.ok(h.notified('clean, check, update'), vim.inspect(h.notes))
end)

test(
    'schema accepts a lua task with a closure',
    function() h.eq(schema.validate_task({ id = 'x', type = 'lua', fn = h.noop }), true) end
)

test(
    'schema rejects a lua task with neither script nor fn',
    function() h.eq(schema.validate_task({ id = 'x', type = 'lua' }), false) end
)

test('schema accepts a cmd task and rejects one without a command', function()
    h.eq(schema.validate_task({ id = 'x', type = 'cmd', cmd = 'Foo' }), true)
    h.eq(schema.validate_task({ id = 'x', type = 'cmd' }), false)
    h.eq(schema.validate_task({ id = 'x', type = 'cmd', cmd = 5 }), false)
end)

test('schema accepts the install phase and rejects any other', function()
    h.eq(schema.validate_task({ id = 'x', type = 'rtp', phase = 'install' }), true)
    h.eq(schema.validate_task({ id = 'x', type = 'rtp', phase = 'later' }), false)
end)

test('schema requires per_commit to be a boolean', function()
    h.eq(schema.validate_task({ id = 'x', type = 'lua', fn = h.noop, per_commit = true }), true)
    h.eq(schema.validate_task({ id = 'x', type = 'lua', fn = h.noop, per_commit = 'yes' }), false)
end)

test(
    'schema rejects the removed track type',
    function() h.eq(schema.validate_task({ id = 'x', type = 'track' }), false) end
)

test('schema accepts function-valued manifest fields', function()
    local manifest = { { name = 'a', repo = 'x/a', build = h.noop, config = h.noop, init = h.noop } }
    h.eq(schema.validate_manifest(manifest), true)
end)

return tests
