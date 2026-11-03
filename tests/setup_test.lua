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

test('the pin of setup is what Sarcina follows, and a pin it cannot use is named', function()
    local own = require('sarcina.self')
    require('sarcina').setup({ pin = { tag = 'v1.0.0', branch = 'main' } })
    h.ok(tasks.wait(2000))
    h.eq(own.pin, { tag = 'v1.0.0', branch = 'main' })
    h.ok(h.notified('pin: ignoring branch, which tag v1.0.0 outranks'), vim.inspect(h.notes))
    require('sarcina').setup({ pin = 'v1.0.0' })
    h.ok(tasks.wait(2000))
    h.eq(own.pin, nil)
    h.ok(
        h.notified('pin names no commit, tag, version or branch, so Sarcina follows stable'),
        vim.inspect(h.notes)
    )
    require('sarcina').setup()
    h.ok(tasks.wait(2000))
    h.eq(own.pin, nil)
end)

test('setup on a Neovim older than 0.11 says so and does nothing else', function()
    local has, echo = vim.fn.has, vim.api.nvim_echo
    local said
    vim.fn.has = function(feature)
        if feature == 'nvim-0.11' then return 0 end
        return has(feature)
    end
    vim.api.nvim_echo = function(chunks) said = chunks end
    local window = require('sarcina.window')
    window.view = 'main'
    local ok, err = pcall(require('sarcina').setup, { ui = { view = 'split' } })
    vim.fn.has, vim.api.nvim_echo = has, echo
    assert(ok, err)
    h.eq(said, { { 'Sarcina needs Neovim 0.11 or newer', 'ErrorMsg' } })
    h.eq(window.view, 'main')
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
    h.eq(require('sarcina.stats').plugin('forgotten.nvim').state, 'disabled')
    vim.fn.delete(paths.install('forgotten.nvim'), 'rf')
    h.notes = {}
    h.reset()
    require('sarcina').setup()
    h.ok(tasks.wait(2000))
    vim.fn.delete(file)
    h.ok(not h.notified('on disk, not in your specs'), vim.inspect(h.notes))
    h.eq(require('sarcina.stats').plugin('forgotten.nvim'), nil)
end)

return tests
