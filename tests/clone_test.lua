local h = require('helpers')
local factory = require('sarcina.task_factory')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function commit(dir)
    vim.fn.system({
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
        'next',
    })
end

local function make_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
    commit(dir)
    return dir
end

local function plugin(name, spec)
    spec = vim.tbl_extend('force', { name = name }, spec)
    return { name = name, tasks = factory.generate(spec) }
end

local function staging_leftovers()
    return vim.fn.glob(require('sarcina.paths').plugins_dir() .. '.staging/*', false, true)
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

-- A plugin whose build counts its runs and fails while `state.fail` is set.
local function counting_build(state)
    return function()
        state.runs = state.runs + 1
        if state.fail then error('build broke') end
    end
end

test('a build runs after the first clone and not on later runs', function()
    local repo, state = make_repo(), { runs = 0 }
    local spec = { repo = repo, build = counting_build(state) }
    h.run({ plugin('built.nvim', spec) })
    h.eq(state.runs, 1)
    h.run({ plugin('built.nvim', spec) })
    h.eq(state.runs, 1)
    h.eq(h.job('built.nvim', 'build').status, 'done')
    h.eq(h.job('built.nvim', 'build').note, 'up to date')
end)

test('a build runs again when the checked-out commit changes', function()
    local repo, state = make_repo(), { runs = 0 }
    local spec = { repo = repo, build = counting_build(state) }
    h.run({ plugin('moved.nvim', spec) })
    commit(paths.install('moved.nvim'))
    h.run({ plugin('moved.nvim', spec) })
    h.eq(state.runs, 2)
    h.run({ plugin('moved.nvim', spec) })
    h.eq(state.runs, 2)
end)

test('a failed build runs again on the next run', function()
    local repo, state = make_repo(), { runs = 0, fail = true }
    local spec = { repo = repo, build = counting_build(state) }
    h.eq(h.run({ plugin('broke.nvim', spec) }).failed, 1)
    h.run({ plugin('broke.nvim', spec) })
    h.eq(state.runs, 2)
    state.fail = false
    h.run({ plugin('broke.nvim', spec) })
    h.eq(state.runs, 3)
    h.run({ plugin('broke.nvim', spec) })
    h.eq(state.runs, 3)
end)

test('a build runs again after the plugin is cloned afresh', function()
    local repo, state = make_repo(), { runs = 0 }
    local spec = { repo = repo, build = counting_build(state) }
    h.run({ plugin('fresh.nvim', spec) })
    vim.fn.delete(paths.install('fresh.nvim'), 'rf')
    h.run({ plugin('fresh.nvim', spec) })
    h.eq(state.runs, 2)
end)

test('init and after hooks are not gated by the commit', function()
    local repo, hooks = make_repo(), { init = 0, after = 0 }
    local spec = {
        repo = repo,
        init = function() hooks.init = hooks.init + 1 end,
        after = function() hooks.after = hooks.after + 1 end,
    }
    h.run({ plugin('hooks.nvim', spec) })
    h.run({ plugin('hooks.nvim', spec) })
    h.eq(hooks, { init = 2, after = 2 })
end)

test('an Ex command build is gated by the commit too', function()
    local runs = 0
    vim.api.nvim_create_user_command('GatedBuild', function() runs = runs + 1 end, {})
    local spec = { repo = make_repo(), build = ':GatedBuild' }
    h.run({ plugin('exbuild.nvim', spec) })
    h.run({ plugin('exbuild.nvim', spec) })
    vim.api.nvim_del_user_command('GatedBuild')
    vim.opt.rtp:remove(paths.install('exbuild.nvim'))
    h.eq(runs, 1)
end)

local function record_of(name) return paths.install(name) .. '/.git/sarcina-build' end

test('a clone records how long the install took, and an install of what is on disk does not', function()
    local installs = require('sarcina.installs')
    local repo = make_repo()
    h.run({ plugin('timed.nvim', { repo = repo }) })
    local saved = installs.get('timed.nvim')
    local took = h.job('timed.nvim', 'install').duration
    h.ok(saved and saved.ms > 0 and math.abs(saved.ms - took) <= 0.05, vim.inspect(saved) .. ' vs ' .. took)
    h.ok(vim.uv.fs_stat(paths.installs_file()), 'the records were not written to a file')
    vim.wait(1100)
    h.run({ plugin('timed.nvim', { repo = repo }) })
    h.eq(h.job('timed.nvim', 'install').note, 'already installed')
    h.eq(installs.get('timed.nvim'), saved)
end)

-- Starts a run of one plugin and returns once its build is running.
local function start_run(spec_plugin)
    require('sarcina.tasks').enqueue(spec_plugin.name, spec_plugin)
    require('sarcina.tasks').run_all(nil, { quiet = true })
    h.ok(vim.wait(2000, function() return h.job(spec_plugin.name, 'build').status == 'running' end, 5))
end

test('a build that takes done runs until it calls it, and only then records the commit', function()
    local release
    local spec = {
        repo = make_repo(),
        build = function(_, done) release = done end,
    }
    local async = plugin('asyncbuild.nvim', spec)
    start_run(async)
    h.ok(vim.wait(2000, function() return release ~= nil end, 5), 'the build function never ran')
    h.eq(h.job('asyncbuild.nvim', 'rtp').status, 'pending')
    h.eq(vim.uv.fs_stat(record_of('asyncbuild.nvim')), nil)
    release(true)
    h.ok(require('sarcina.tasks').wait(2000))
    h.eq(h.job('asyncbuild.nvim', 'build').status, 'done')
    h.eq(h.job('asyncbuild.nvim', 'rtp').status, 'done')
    h.eq(
        vim.fn.readfile(record_of('asyncbuild.nvim'))[1],
        vim.trim(vim.fn.system({
            'git',
            '-C',
            paths.install('asyncbuild.nvim'),
            'rev-parse',
            'HEAD',
        }))
    )
end)

test('a build may call done from a libuv callback, as a finished process does', function()
    local spec = {
        repo = make_repo(),
        build = function(_, done)
            local timer = vim.uv.new_timer()
            timer:start(30, 0, function()
                timer:close()
                done(true)
            end)
        end,
    }
    h.eq(h.run({ plugin('fastasync.nvim', spec) }).failed, 0)
    h.eq(h.job('fastasync.nvim', 'build').status, 'done')
    h.ok(vim.uv.fs_stat(record_of('fastasync.nvim')), 'no record after the build')
end)

test('done(false, message) fails the build, leaves no record, and skips the rest', function()
    local spec = { repo = make_repo(), build = function(_, done) done(false, 'cargo exploded') end }
    h.eq(h.run({ plugin('asyncfail.nvim', spec) }).failed, 1)
    h.eq(h.job('asyncfail.nvim', 'build').error, 'cargo exploded')
    h.eq(h.job('asyncfail.nvim', 'rtp').status, 'skipped')
    h.eq(vim.uv.fs_stat(record_of('asyncfail.nvim')), nil)
end)

test('a build that takes done and raises fails the job instead of hanging', function()
    local spec = {
        repo = make_repo(),
        build = function(_, done)
            if done then error('before done', 0) end
        end,
    }
    h.eq(h.run({ plugin('asyncraise.nvim', spec) }).failed, 1)
    h.eq(h.job('asyncraise.nvim', 'build').error, 'before done')
end)

test('a build with one parameter stays synchronous and gets the plugin', function()
    local seen
    local spec = { repo = make_repo(), build = function(p) seen = { p.name, p.dir } end }
    h.eq(h.run({ plugin('syncbuild.nvim', spec) }).failed, 0)
    h.eq(seen, { 'syncbuild.nvim', paths.install('syncbuild.nvim') })
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
