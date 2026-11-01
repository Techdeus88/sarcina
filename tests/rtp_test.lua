local h = require('helpers')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- plugin/ and after/plugin/ each set a global; the second only if the first already ran.
local function layered_plugin(name)
    local dir = paths.install(name)
    vim.fn.mkdir(dir .. '/plugin', 'p')
    vim.fn.mkdir(dir .. '/after/plugin', 'p')
    vim.fn.writefile({ 'vim.g.main_ran = true' }, dir .. '/plugin/main.lua')
    vim.fn.writefile({ 'vim.g.after_ran = vim.g.main_ran == true' }, dir .. '/after/plugin/after.lua')
end

local RTP_TASK = "{ id = 'rtp', type = 'rtp' }"

-- Runs one task of the plugin in a child Neovim, before startup finishes or after it, and reports the globals.
local function run_child(name, task, before_startup)
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({
        string.format('vim.opt.rtp:prepend(%q)', root),
        "local tasks = require('sarcina.tasks')",
        string.format('tasks.enqueue(%q, { tasks = { %s } })', name, task),
        'tasks.run_all()',
        before_startup and 'tasks.wait(5000)' or '',
        "vim.api.nvim_create_autocmd('VimEnter', { callback = function()",
        '    tasks.wait(5000)',
        '    io.stdout:write(vim.json.encode({ main = vim.g.main_ran, after = vim.g.after_ran, built = vim.g.built }))',
        '    vim.cmd.qa()',
        'end })',
    }, script)
    local res = vim.system({ vim.v.progpath, '--headless', '-i', 'NONE', '-u', script }, { text = true })
        :wait(10000)
    h.eq(res.code, 0, res.stderr)
    return vim.json.decode(res.stdout)
end

test('a late rtp task sources plugin/ and then after/plugin', function()
    layered_plugin('late.nvim')
    h.eq(run_child('late.nvim', RTP_TASK, false), { main = true, after = true })
end)

test('an rtp task before startup leaves plugin/ and after/plugin to Neovim', function()
    layered_plugin('early.nvim')
    h.eq(run_child('early.nvim', RTP_TASK, true), { main = true, after = true })
end)

test('a cmd task runs a command that the plugin defines in plugin/', function()
    local dir = paths.install('cmd.nvim')
    vim.fn.mkdir(dir .. '/plugin', 'p')
    local define = "vim.api.nvim_create_user_command('CmdBuild', function() vim.g.built = true end, {})"
    vim.fn.writefile({ define }, dir .. '/plugin/cmd.lua')
    local task = "{ id = 'build', type = 'cmd', cmd = 'CmdBuild' }"
    h.eq(run_child('cmd.nvim', task, false), { built = true })
end)

test('a cmd task passes its arguments through and puts the plugin on the runtimepath', function()
    local dir = paths.install('args.nvim')
    vim.fn.mkdir(dir, 'p')
    vim.api.nvim_create_user_command(
        'ArgsBuild',
        function(opts) vim.g.build_args = opts.args end,
        { nargs = '*' }
    )
    h.run({
        { name = 'args.nvim', tasks = { { id = 'build', type = 'cmd', cmd = 'ArgsBuild install now' } } },
    })
    vim.api.nvim_del_user_command('ArgsBuild')
    vim.opt.rtp:remove(dir)
    h.eq(h.job('args.nvim', 'build').status, 'done')
    h.eq(vim.g.build_args, 'install now')
end)

test('a failing cmd task reports the editor error', function()
    h.run({ { name = 'nocmd.nvim', tasks = { { id = 'build', type = 'cmd', cmd = 'NoSuchSarcinaCmd' } } } })
    local job = h.job('nocmd.nvim', 'build')
    h.eq(job.status, 'failed')
    h.ok(job.error:find('E492', 1, true), job.error)
end)

test('the after dir goes behind the plugin on the runtimepath', function()
    layered_plugin('order.nvim')
    h.run({ { name = 'order.nvim', tasks = { { id = 'rtp', type = 'rtp' } } } })
    local dir = paths.install('order.nvim')
    local rtp = vim.opt.rtp:get()
    local at = vim.fn.index(rtp, dir)
    h.ok(at >= 0, 'plugin dir missing from runtimepath')
    h.eq(rtp[#rtp], dir .. '/after')
    h.ok(vim.fn.index(rtp, dir .. '/after') > at)
    vim.opt.rtp:remove(dir)
    vim.opt.rtp:remove(dir .. '/after')
end)

return tests
