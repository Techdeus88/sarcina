local h = require('helpers')
local factory = require('sarcina.task_factory')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function make_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
    local commit = {
        'git',
        '-C',
        dir,
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '-q',
        '--allow-empty',
        '-m',
        'init',
    }
    vim.fn.system(commit)
    return dir
end

local function plugin(name, spec)
    spec = vim.tbl_extend('force', { name = name }, spec)
    return { name = name, tasks = factory.generate(spec) }
end

local function staging_leftovers()
    return vim.fn.glob(vim.fn.stdpath('cache') .. '/sarcina_staging/*', false, true)
end

if vim.fn.executable('git') == 0 then return {} end

test('clones through the install task and adds the plugin to the runtimepath', function()
    local summary = h.run({ plugin('demo.nvim', { repo = make_repo() }) })
    h.eq(summary.failed, 0)
    local dest = paths.install('demo.nvim')
    h.ok(vim.uv.fs_stat(dest .. '/.git'), 'clone missing at ' .. dest)
    h.ok(vim.o.runtimepath:find(dest, 1, true), 'plugin dir missing from runtimepath')
    h.eq(staging_leftovers(), {})
end)

test('a second run skips the clone but still runs the other tasks', function()
    local repo = make_repo()
    h.run({ plugin('again.nvim', { repo = repo }) })
    h.run({ plugin('again.nvim', { repo = repo }) })
    h.eq(h.job('again.nvim', 'install').status, 'done')
    h.eq(h.job('again.nvim', 'install').note, 'already installed')
    h.eq(h.job('again.nvim', 'rtp').status, 'done')
end)

test('a plugin that turns lazy reuses its clone and never touches a pack dir', function()
    local repo = make_repo()
    h.run({ plugin('flip.nvim', { repo = repo }) })
    h.run({ plugin('flip.nvim', { repo = repo, event = 'BufRead' }) })
    h.eq(h.job('flip.nvim', 'install').note, 'already installed')
    h.eq(vim.fn.isdirectory(vim.fn.stdpath('data') .. '/site/pack'), 0)
end)

test('a failed clone is reported, cleaned up, and stops the plugin', function()
    local summary = h.run({ plugin('ghost.nvim', { repo = vim.fn.tempname() .. '/missing' }) })
    h.eq(summary, { total = 2, done = 0, failed = 1, skipped = 1 })
    h.ok(#h.job('ghost.nvim', 'install').error > 0)
    h.eq(h.job('ghost.nvim', 'rtp').status, 'skipped')
    h.eq(vim.uv.fs_stat(paths.install('ghost.nvim')), nil)
    h.eq(staging_leftovers(), {})
end)

test('rtp fails when the plugin directory is missing', function()
    h.run({ { name = 'nodir', tasks = { { id = 'rtp', type = 'rtp' } } } })
    h.eq(h.job('nodir', 'rtp').status, 'failed')
    h.ok(h.job('nodir', 'rtp').error:find('plugin directory missing', 1, true))
end)

return tests
