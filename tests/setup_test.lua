local h = require('helpers')
local tasks = require('sarcina.tasks')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

test('setup runs quietly when everything succeeds', function()
    local dir = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(dir, 'p')
    local file = dir .. '/quiet_setup.lua'
    vim.fn.writefile({
        'return {',
        "    { name = 'quietsetup', tasks = { { id = 'a', type = 'lua', fn = function() vim.g.quiet_setup_ran = true end } } },",
        '}',
    }, file)
    require('sarcina').setup()
    h.ok(tasks.wait(2000))
    vim.fn.delete(file)
    h.eq(vim.g.quiet_setup_ran, true)
    vim.g.quiet_setup_ran = nil
    h.eq(h.notes, {})
end)

test('setup still reports a failure', function()
    local dir = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(dir, 'p')
    local file = dir .. '/failing_setup.lua'
    vim.fn.writefile({
        'return {',
        "    { name = 'failingsetup', tasks = { { id = 'a', type = 'lua', fn = function() error('nope') end } } },",
        '}',
    }, file)
    require('sarcina').setup()
    h.ok(tasks.wait(2000))
    vim.fn.delete(file)
    h.eq(#h.notes, 1)
    h.ok(h.notified('1 failed'))
end)

return tests
