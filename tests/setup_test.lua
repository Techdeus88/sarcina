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

test('setup warns about a plugin on disk that no spec owns, and about nothing else', function()
    local paths = require('sarcina.paths')
    local dir = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(dir, 'p')
    local file = dir .. '/stale_setup.lua'
    vim.fn.writefile({
        'return {',
        "    { name = 'kept', tasks = { { id = 'a', type = 'lua', fn = function() end } } },",
        '}',
    }, file)
    vim.fn.mkdir(paths.install('forgotten.nvim'), 'p')
    require('sarcina').setup()
    h.ok(tasks.wait(2000))
    h.ok(h.notified('1 plugin on disk, not in your specs: forgotten.nvim'), vim.inspect(h.notes))
    h.eq(h.stray, {})
    vim.fn.delete(paths.install('forgotten.nvim'), 'rf')
    h.notes = {}
    h.reset()
    require('sarcina').setup()
    h.ok(tasks.wait(2000))
    vim.fn.delete(file)
    h.ok(not h.notified('on disk, not in your specs'), vim.inspect(h.notes))
end)

return tests
