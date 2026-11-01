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

-- Runs the plugin's rtp task in a child Neovim, before startup finishes or after it, and reports the globals.
local function run_child(name, before_startup)
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({
        string.format('vim.opt.rtp:prepend(%q)', root),
        "local tasks = require('sarcina.tasks')",
        string.format("tasks.enqueue(%q, { tasks = { { id = 'rtp', type = 'rtp' } } })", name),
        'tasks.run_all()',
        before_startup and 'tasks.wait(5000)' or '',
        "vim.api.nvim_create_autocmd('VimEnter', { callback = function()",
        '    tasks.wait(5000)',
        '    io.stdout:write(vim.json.encode({ main = vim.g.main_ran, after = vim.g.after_ran }))',
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
    h.eq(run_child('late.nvim', false), { main = true, after = true })
end)

test('an rtp task before startup leaves plugin/ and after/plugin to Neovim', function()
    layered_plugin('early.nvim')
    h.eq(run_child('early.nvim', true), { main = true, after = true })
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
