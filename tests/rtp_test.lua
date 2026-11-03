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
local function run_child(name, task, before_startup, probe)
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({
        string.format('vim.opt.rtp:prepend(%q)', root),
        "local tasks = require('sarcina.tasks')",
        string.format('tasks.enqueue(%q, { tasks = { %s } })', name, task),
        'tasks.run_all()',
        before_startup and 'tasks.wait(5000)' or '',
        -- Nested, so a probe that edits a file gets its filetype: before Neovim 0.13 a command in an autocmd fires
        -- no autocmds of its own otherwise.
        "vim.api.nvim_create_autocmd('VimEnter', { nested = true, callback = function()",
        '    tasks.wait(5000)',
        probe and ('    _G.probe_value = (function() ' .. probe .. ' end)()') or '',
        '    io.stdout:write(vim.json.encode({ main = vim.g.main_ran, after = vim.g.after_ran, built = vim.g.built, count = vim.g.main_count, probe = _G.probe_value }))',
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

-- plugin/ counts how many times it is sourced, and lua/ has a module a build can require.
local function counted_plugin(name)
    local dir = paths.install(name)
    vim.fn.mkdir(dir .. '/plugin', 'p')
    vim.fn.mkdir(dir .. '/lua/counted', 'p')
    vim.fn.writefile(
        { 'vim.g.main_count = (vim.g.main_count or 0) + 1', 'vim.g.main_ran = true' },
        dir .. '/plugin/main.lua'
    )
    vim.fn.writefile({ 'return { ok = true }' }, dir .. '/lua/counted/init.lua')
end

-- A build that records whether plugin/ had run when it was called and whether it could require the plugin.
local BUILD_TASK = "{ id = 'build', type = 'lua', per_commit = true, fn = function() "
    .. "vim.g.built = vim.g.main_ran == nil and require('counted').ok end }"

test('a function build finds the plugin modules, but its plugin/ files wait for the rtp task', function()
    counted_plugin('prebuild.nvim')
    local seen = run_child('prebuild.nvim', BUILD_TASK .. ', ' .. RTP_TASK, false)
    h.eq(seen.built, true)
    h.eq(seen.main, true)
end)

test('plugin/ is sourced once, though a build and two rtp tasks put the plugin on the runtimepath', function()
    counted_plugin('once.nvim')
    local seen =
        run_child('once.nvim', BUILD_TASK .. ', ' .. RTP_TASK .. ', { id = "again", type = "rtp" }', false)
    h.eq(seen.count, 1)
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

test(
    'the rtp task makes the help of a plugin findable, and leaves the doc/tags a plugin ships alone',
    function()
        local dir = paths.install('docs.nvim')
        vim.fn.mkdir(dir .. '/doc', 'p')
        vim.fn.writefile({ '*docs.txt*  A plugin', '', 'About *docs-topic* here.' }, dir .. '/doc/docs.txt')
        h.eq(h.run({ { name = 'docs.nvim', tasks = { { id = 'rtp', type = 'rtp' } } } }).failed, 0)
        h.ok(vim.uv.fs_stat(dir .. '/doc/tags'), 'no doc/tags was made')
        h.ok(pcall(vim.cmd, 'help docs-topic'), 'the help of the plugin is not found')
        vim.cmd('helpclose')
        vim.opt.rtp:remove(dir)
        local kept = paths.install('kept.nvim')
        vim.fn.mkdir(kept .. '/doc', 'p')
        vim.fn.writefile({ '*kept.txt*  A plugin', '', 'About *kept-topic* here.' }, kept .. '/doc/kept.txt')
        vim.fn.writefile({ 'kept-topic\tkept.txt\t/*kept-topic*' }, kept .. '/doc/tags')
        h.run({ { name = 'kept.nvim', tasks = { { id = 'rtp', type = 'rtp' } } } })
        h.eq(vim.fn.readfile(kept .. '/doc/tags'), { 'kept-topic\tkept.txt\t/*kept-topic*' })
        vim.opt.rtp:remove(kept)
    end
)

-- A plugin whose ftdetect scripts, one in Lua and one in Vim script, each detect an extension of their own.
local function ftdetect_plugin(name)
    local dir = paths.install(name)
    vim.fn.mkdir(dir .. '/ftdetect', 'p')
    vim.fn.writefile(
        { "vim.filetype.add({ extension = { zzlua = 'zzlua' } })" },
        dir .. '/ftdetect/zzlua.lua'
    )
    vim.fn.writefile({ 'autocmd BufRead,BufNewFile *.zzvim setfiletype zzvim' }, dir .. '/ftdetect/zzvim.vim')
end

local DETECT = "local function ft(ext) local f = vim.fn.tempname() .. '.' .. ext; vim.fn.writefile({ 'x' }, f); "
    .. "vim.cmd('edit ' .. f); return vim.bo.filetype end return ft('zzlua') .. ',' .. ft('zzvim')"

test(
    'a plugin loaded after startup has its ftdetect scripts applied, and one loaded before it still does',
    function()
        ftdetect_plugin('late-ft.nvim')
        h.eq(run_child('late-ft.nvim', RTP_TASK, false, DETECT).probe, 'zzlua,zzvim')
        ftdetect_plugin('early-ft.nvim')
        h.eq(run_child('early-ft.nvim', RTP_TASK, true, DETECT).probe, 'zzlua,zzvim')
    end
)

return tests
