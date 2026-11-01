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

test(':Sarcina panel says so when there is nothing to show', function()
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina panel')
    h.ok(h.notified('No task activity yet'))
end)

test('completes subcommand names', function() h.eq(require('sarcina.cli').complete('pa'), { 'panel' }) end)

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
