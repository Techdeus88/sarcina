local h = require('helpers')
local installer = require('sarcina.installer')
local paths = require('sarcina.paths')
local resolver = require('sarcina.resolver')
local scheduler = require('sarcina.scheduler')
local tasks = require('sarcina.tasks')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function module_body(tag, extra)
    return table.concat({
        'local M = {}',
        'function M.setup(opts)',
        '  _G.lazy_log = _G.lazy_log or {}',
        "  table.insert(_G.lazy_log, 'setup:" .. tag .. "')",
        '  ' .. (extra or ''),
        'end',
        'return M',
    }, '\n')
end

-- Installs a fixture plugin where the rtp task expects to find it.
local function fixture_plugin(name, module, extra)
    h.plugin_dir({ [module] = module_body(name, extra) }, paths.install(name))
end

local function start(specs)
    installer.install_all(resolver.resolve(specs))
    h.ok(tasks.wait(5000), 'startup tasks did not finish')
end

local function log() return _G.lazy_log or {} end

local function loaded(name)
    return vim.wait(2000, function() return scheduler.state(name) == 'loaded' end)
end

test('describe summarizes every trigger kind', function()
    local triggers =
        { event = { 'BufRead' }, ft = { 'lua' }, cmd = { 'Foo' }, keys = { '<F5>', { '<F6>', mode = 'v' } } }
    h.eq(scheduler.describe(triggers), 'BufRead, ft:lua, :Foo, <F5>, <F6>')
end)

test('startup registers stubs and loads nothing', function()
    local extra = "vim.api.nvim_create_user_command('CmdPlug', function() end, {})"
    fixture_plugin('cmdplug.nvim', 'cmdplug', extra)
    start({ { name = 'cmdplug.nvim', cmd = 'CmdPlug', opts = {} } })
    h.eq(scheduler.state('cmdplug.nvim'), 'waiting')
    h.eq(_G.lazy_log, nil)
    h.eq(vim.fn.exists(':CmdPlug'), 2)
    h.ok(h.job('cmdplug.nvim', 'load_trigger').note:find('waiting for :CmdPlug', 1, true))
    h.eq(h.job('cmdplug.nvim', 'rtp'), nil)
end)

test('a command trigger loads the plugin, then runs the command', function()
    local extra =
        "vim.api.nvim_create_user_command('CmdRun', function(o) table.insert(_G.lazy_log, 'cmd:' .. o.args) end, { nargs = '*' })"
    fixture_plugin('cmdrun.nvim', 'cmdrun', extra)
    start({ { name = 'cmdrun.nvim', cmd = 'CmdRun', opts = {} } })
    vim.cmd('CmdRun hello')
    h.ok(vim.wait(2000, function() return #log() >= 2 end), 'plugin never loaded')
    h.eq(log(), { 'setup:cmdrun.nvim', 'cmd:hello' })
    h.eq(scheduler.state('cmdrun.nvim'), 'loaded')
end)

test('a load triggered later runs quietly', function()
    local extra = "vim.api.nvim_create_user_command('CmdQuiet', function() end, {})"
    fixture_plugin('cmdquiet.nvim', 'cmdquiet', extra)
    start({ { name = 'cmdquiet.nvim', cmd = 'CmdQuiet', opts = {} } })
    h.notes = {}
    vim.cmd('CmdQuiet')
    h.ok(loaded('cmdquiet.nvim'))
    h.eq(h.notes, {})
end)

test('the config task runs on load, with opts', function()
    fixture_plugin('cfgplug.nvim', 'cfgplug', '')
    local seen
    start({
        {
            name = 'cfgplug.nvim',
            cmd = 'CfgPlug',
            opts = { size = 3 },
            config = function(plugin, opts)
                seen = { name = plugin.name, size = opts.size }
                vim.api.nvim_create_user_command('CfgPlug', function() end, {})
            end,
        },
    })
    h.eq(seen, nil)
    vim.cmd('CfgPlug')
    h.ok(loaded('cfgplug.nvim'))
    h.eq(seen, { name = 'cfgplug.nvim', size = 3 })
end)

test("an event trigger replays only the plugin's own handlers", function()
    local extra =
        "vim.api.nvim_create_autocmd('User', { pattern = 'EvtPlug', callback = function() table.insert(_G.lazy_log, 'plugin-handler') end })"
    fixture_plugin('evtplug.nvim', 'evtplug', extra)
    vim.api.nvim_create_autocmd('User', {
        pattern = 'EvtPlug',
        callback = function()
            _G.lazy_log = _G.lazy_log or {}
            table.insert(_G.lazy_log, 'other-handler')
        end,
    })
    start({ { name = 'evtplug.nvim', event = 'User EvtPlug', opts = {} } })
    vim.api.nvim_exec_autocmds('User', { pattern = 'EvtPlug' })
    h.ok(loaded('evtplug.nvim'))
    local counts = {}
    for _, entry in ipairs(log()) do
        counts[entry] = (counts[entry] or 0) + 1
    end
    vim.api.nvim_clear_autocmds({ event = 'User', pattern = 'EvtPlug' })
    h.eq(counts['plugin-handler'], 1)
    h.eq(counts['other-handler'], 1)
end)

test('replay runs a buffer-local autocmd for the triggering buffer', function()
    local extra =
        "vim.api.nvim_create_autocmd('BufEnter', { buffer = 0, callback = function() table.insert(_G.lazy_log, 'buf-handler') end })"
    fixture_plugin('bufplug.nvim', 'bufplug', extra)
    start({ { name = 'bufplug.nvim', event = 'BufEnter', opts = {} } })
    vim.cmd('enew!')
    h.ok(loaded('bufplug.nvim'))
    h.eq(log(), { 'setup:bufplug.nvim', 'buf-handler' })
end)

test('a filetype trigger loads on the first matching buffer', function()
    local extra =
        "vim.api.nvim_create_autocmd('FileType', { pattern = 'ftplugtest', callback = function() table.insert(_G.lazy_log, 'ft-handler') end })"
    fixture_plugin('ftplug.nvim', 'ftplug', extra)
    start({ { name = 'ftplug.nvim', ft = 'ftplugtest', opts = {} } })
    h.eq(scheduler.state('ftplug.nvim'), 'waiting')
    vim.cmd('enew!')
    vim.bo.filetype = 'ftplugtest'
    h.ok(loaded('ftplug.nvim'))
    h.eq(log(), { 'setup:ftplug.nvim', 'ft-handler' })
    vim.api.nvim_clear_autocmds({ event = 'FileType', pattern = 'ftplugtest' })
end)

test('a lazy load adds its rows to the startup run and keeps earlier failures', function()
    fixture_plugin('rows.nvim', 'rows', "vim.api.nvim_create_user_command('RowsCmd', function() end, {})")
    start({
        { name = 'broken', tasks = { h.lua('x', function() error('no') end) } },
        { name = 'rows.nvim', cmd = 'RowsCmd', opts = {} },
    })
    h.notes = {}
    vim.cmd('RowsCmd')
    h.ok(loaded('rows.nvim'))
    local ids = vim.tbl_map(function(job) return job.plugin .. '/' .. job.id end, tasks.snapshot().jobs)
    h.eq(ids, { 'broken/x', 'rows.nvim/load_trigger', 'rows.nvim/rtp', 'rows.nvim/load' })
    h.eq(tasks.snapshot().counts.failed, 1)
    h.eq(h.notes, {})
end)

test("a key trigger swaps its stub for the plugin's mapping", function()
    fixture_plugin('keyplug.nvim', 'keyplug', "vim.keymap.set('n', '<F9>', function() end)")
    start({ { name = 'keyplug.nvim', keys = { '<F9>' }, opts = {} } })
    local stub = vim.fn.maparg('<F9>', 'n', false, true)
    h.eq(type(stub.callback), 'function')
    stub.callback()
    h.ok(loaded('keyplug.nvim'))
    local real = vim.fn.maparg('<F9>', 'n', false, true)
    h.ok(real.callback ~= stub.callback, 'stub was not replaced')
    pcall(vim.keymap.del, 'n', '<F9>')
end)

test('a key with an rhs becomes a real mapping once the plugin loads', function()
    fixture_plugin('rhsplug.nvim', 'rhsplug', '')
    local key = { '<F8>', '<cmd>let g:rhs_key = 1<cr>', desc = 'Demo' }
    start({ { name = 'rhsplug.nvim', keys = { key }, opts = {} } })
    local stub = vim.fn.maparg('<F8>', 'n', false, true)
    h.eq(type(stub.callback), 'function')
    stub.callback()
    h.ok(loaded('rhsplug.nvim'))
    local real = vim.fn.maparg('<F8>', 'n', false, true)
    h.eq(real.rhs, '<cmd>let g:rhs_key = 1<cr>')
    h.eq(real.desc, 'Demo')
    pcall(vim.keymap.del, 'n', '<F8>')
end)

test('any trigger defines the mappings of the keys with an rhs', function()
    fixture_plugin('rhscmd.nvim', 'rhscmd', "vim.api.nvim_create_user_command('RhsCmd', function() end, {})")
    start({
        { name = 'rhscmd.nvim', cmd = 'RhsCmd', keys = { { '<F7>', '<cmd>RhsCmd<cr>' } }, opts = {} },
    })
    vim.cmd('RhsCmd')
    h.ok(loaded('rhscmd.nvim'))
    h.eq(vim.fn.maparg('<F7>', 'n', false, true).rhs, '<cmd>RhsCmd<cr>')
    pcall(vim.keymap.del, 'n', '<F7>')
end)

test('a filetype trigger armed late catches up with a buffer that is already open', function()
    local extra =
        "vim.api.nvim_create_autocmd('FileType', { group = vim.api.nvim_create_augroup('catchft_test', { clear = true }), pattern = 'catchft', callback = function() table.insert(_G.lazy_log, 'ft-handler') end })"
    fixture_plugin('catchft.nvim', 'catchft', extra)
    vim.cmd('new')
    vim.bo.filetype = 'catchft'
    start({ { name = 'catchft.nvim', ft = 'catchft', opts = {} } })
    h.ok(loaded('catchft.nvim'))
    vim.cmd('bwipeout!')
    pcall(vim.api.nvim_del_augroup_by_name, 'catchft_test')
    h.eq(log(), { 'setup:catchft.nvim', 'ft-handler' })
end)

test('an event trigger armed late catches up with an open file buffer and replays its handler', function()
    local extra =
        "vim.api.nvim_create_autocmd('BufRead', { group = vim.api.nvim_create_augroup('catchev_test', { clear = true }), callback = function() table.insert(_G.lazy_log, 'read-handler') end })"
    fixture_plugin('catchev.nvim', 'catchev', extra)
    local path = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'x' }, path)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    start({ { name = 'catchev.nvim', event = 'BufRead *.lua', opts = {} } })
    h.ok(loaded('catchev.nvim'))
    vim.cmd('bwipeout!')
    vim.fn.delete(path)
    pcall(vim.api.nvim_del_augroup_by_name, 'catchev_test')
    h.eq(log(), { 'setup:catchev.nvim', 'read-handler' })
end)

test('a trigger armed late does not catch up when no open buffer matches', function()
    fixture_plugin('catchmiss.nvim', 'catchmiss', '')
    local path = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'x' }, path)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    start({
        { name = 'catchmiss.nvim', event = 'BufRead *.rs', ft = 'rust', opts = {} },
    })
    vim.wait(100)
    h.eq(scheduler.state('catchmiss.nvim'), 'waiting')
    vim.cmd('bwipeout!')
    vim.fn.delete(path)
end)

test('commands and keys never catch up, only a user action loads them', function()
    fixture_plugin('catchcmd.nvim', 'catchcmd', '')
    vim.cmd('new')
    vim.bo.filetype = 'catchcmd'
    start({
        { name = 'catchcmd.nvim', cmd = 'CatchCmd', keys = { '<F2>' }, opts = {} },
    })
    vim.wait(100)
    h.eq(scheduler.state('catchcmd.nvim'), 'waiting')
    vim.cmd('bwipeout!')
end)

test('a plugin that is loaded is not armed again when it is registered again', function()
    fixture_plugin('catchagain.nvim', 'catchagain', '')
    start({ { name = 'catchagain.nvim', cmd = 'CatchAgainCmd', opts = {} } })
    scheduler.load('catchagain.nvim')
    h.ok(loaded('catchagain.nvim'))
    scheduler.register('catchagain.nvim', { triggers = { cmd = { 'CatchAgainCmd' } }, deferred = {} })
    h.eq(scheduler.state('catchagain.nvim'), 'loaded')
    h.eq(vim.fn.exists(':CatchAgainCmd'), 0)
end)

test('loading a plugin loads its lazy dependencies first', function()
    local extra_a = "vim.api.nvim_create_user_command('DepA', function() end, {})"
    fixture_plugin('depb.nvim', 'depb', '')
    fixture_plugin('depa.nvim', 'depa', extra_a)
    start({
        { name = 'depa.nvim', deps = { 'depb.nvim' }, cmd = 'DepA', opts = {} },
        { name = 'depb.nvim', event = 'User DepB', opts = {} },
    })
    h.eq(scheduler.state('depb.nvim'), 'waiting')
    vim.cmd('DepA')
    h.ok(loaded('depa.nvim'))
    h.eq(log(), { 'setup:depb.nvim', 'setup:depa.nvim' })
    h.eq(scheduler.state('depb.nvim'), 'loaded')
end)

test('an eager plugin pulls its lazy dependency in at startup', function()
    fixture_plugin('eagerdep.nvim', 'eagerdep', '')
    fixture_plugin('eagerapp.nvim', 'eagerapp', '')
    start({
        { name = 'eagerapp.nvim', deps = { 'eagerdep.nvim' }, opts = {} },
        { name = 'eagerdep.nvim', cmd = 'EagerDep', opts = {} },
    })
    h.eq(scheduler.state('eagerdep.nvim'), nil)
    h.eq(log(), { 'setup:eagerdep.nvim', 'setup:eagerapp.nvim' })
end)

test('a failed load leaves the plugin failed and skips the replay', function()
    start({ { name = 'ghostplug.nvim', cmd = 'GhostPlug', opts = {} } })
    vim.cmd('GhostPlug')
    h.ok(vim.wait(2000, function() return scheduler.state('ghostplug.nvim') == 'failed' end))
    h.eq(vim.fn.exists(':GhostPlug'), 0)
    h.eq(h.job('ghostplug.nvim', 'rtp').status, 'failed')
    h.ok(h.notified('1 failed'))
    h.eq(h.notified('Running :GhostPlug'), false)
end)

test('loading an unknown or loaded plugin does nothing', function()
    scheduler.load('nobody')
    fixture_plugin('twice.nvim', 'twice', "vim.api.nvim_create_user_command('Twice', function() end, {})")
    start({ { name = 'twice.nvim', cmd = 'Twice', opts = {} } })
    scheduler.load('twice.nvim')
    h.ok(loaded('twice.nvim'))
    scheduler.load('twice.nvim')
    vim.wait(100)
    h.eq(log(), { 'setup:twice.nvim' })
end)

return tests
