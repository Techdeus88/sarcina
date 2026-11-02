local h = require('helpers')
local paths = require('sarcina.paths')
local tasks = require('sarcina.tasks')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

if vim.fn.executable('git') == 0 then return {} end

local function specs_dir()
    local dir = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(dir, 'p')
    return dir
end

-- The manifest is exactly `plugins` ({ name, remote, extra }), each cloned from its remote and counting its config
-- calls in _G.sync_configs. `extra` is more fields of the spec, as Lua.
local function manifest(plugins)
    for _, file in ipairs(vim.fn.glob(specs_dir() .. '/*.lua', false, true)) do
        vim.fn.delete(file)
    end
    local lines = { 'return {' }
    for _, plugin in ipairs(plugins) do
        table.insert(
            lines,
            string.format(
                '    { name = %q, repo = %q, config = function() _G.sync_configs[%q] = (_G.sync_configs[%q] or 0) + 1 end, %s },',
                plugin.name,
                'file://' .. plugin.remote,
                plugin.name,
                plugin.name,
                plugin.extra or ''
            )
        )
    end
    table.insert(lines, '}')
    vim.fn.writefile(lines, specs_dir() .. '/sync_test.lua')
end

local function empty_plugins_dir()
    vim.fn.delete(paths.plugins_dir(), 'rf')
    vim.fn.mkdir(paths.plugins_dir(), 'p')
end

local function exists(name) return vim.uv.fs_stat(paths.install(name)) ~= nil end

-- A test starts with an empty plugins directory and no config calls.
local function fresh()
    empty_plugins_dir()
    _G.sync_configs = {}
end

local function command(name, bang)
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina ' .. name .. (bang and '!' or ''))
    h.ok(tasks.wait(15000), 'the run did not finish')
end

local function sync(bang) command('sync', bang) end

local function install() command('install') end

-- A plugin that is on disk already, as an earlier session left it.
local function installed(name, remote)
    vim.fn.system({ 'git', 'clone', '-q', '--depth', '1', 'file://' .. remote, paths.install(name) })
end

local function loaded(name) return vim.tbl_contains(vim.opt.rtp:get(), paths.install(name)) end

test('a second install leaves a loaded plugin alone, so its config runs once', function()
    fresh()
    local remote = h.upstream()
    manifest({ { name = 'inonce.nvim', remote = remote } })
    install()
    h.ok(h.notified('Installing 1: inonce.nvim'), vim.inspect(h.notes))
    h.ok(loaded('inonce.nvim'), 'the plugin is not loaded')
    install()
    h.eq(_G.sync_configs, { ['inonce.nvim'] = 1 })
    h.ok(h.notified('Every plugin is installed and loaded'), vim.inspect(h.notes))
end)

test('install loads a plugin that is on disk but has not loaded in this session', function()
    fresh()
    local remote = h.upstream()
    installed('inondisk.nvim', remote)
    manifest({ { name = 'inondisk.nvim', remote = remote } })
    install()
    h.ok(h.notified('Loading 1: inondisk.nvim'), vim.inspect(h.notes))
    h.eq(_G.sync_configs, { ['inondisk.nvim'] = 1 })
    h.ok(loaded('inondisk.nvim'), 'the plugin is not loaded')
end)

test('install runs a plugin again when a failure stopped it before it loaded', function()
    fresh()
    local remote = h.upstream()
    manifest({
        {
            name = 'inretry.nvim',
            remote = remote,
            extra = "build = function() if not _G.sync_fixed then error('not yet', 0) end end",
        },
    })
    install()
    h.eq(h.job('inretry.nvim', 'build').error, 'not yet')
    h.eq(_G.sync_configs, {})
    _G.sync_fixed = true
    install()
    _G.sync_fixed = nil
    h.eq(h.job('inretry.nvim', 'build').status, 'done')
    h.eq(_G.sync_configs, { ['inretry.nvim'] = 1 })
end)

test('install leaves a plugin that waits for its trigger armed as it is', function()
    fresh()
    local remote = h.upstream()
    manifest({ { name = 'inarmed.nvim', remote = remote, extra = "cmd = 'SyncArmedCmd'" } })
    install()
    h.eq(h.job('inarmed.nvim', 'load_trigger').status, 'done')
    local jobs = #require('sarcina.track').jobs_of('inarmed.nvim')
    install()
    h.eq(#require('sarcina.track').jobs_of('inarmed.nvim'), jobs)
    h.eq(_G.sync_configs, {})
end)

test('pending leaves out the plugins that loaded, wait for a trigger, or are queued', function()
    local noop = h.noop
    h.run({
        { name = 'pdone', tasks = { h.lua('rtp', noop) } },
        { name = 'parmed', tasks = { h.lua('load_trigger', noop) } },
        { name = 'pfailed', tasks = { h.lua('build', function() error('no') end), h.lua('rtp', noop) } },
    })
    require('sarcina.tasks').enqueue('pqueued', { tasks = { h.lua('rtp', noop) } })
    local pending = require('sarcina.installer').pending({
        { name = 'pdone' },
        { name = 'parmed' },
        { name = 'pfailed' },
        { name = 'pqueued' },
        { name = 'pnew' },
    })
    h.eq(h.names(pending), { 'pfailed', 'pnew' })
    h.ok(tasks.wait(5000))
end)

test('sync installs and loads what has not loaded, and leaves the loaded plugins alone', function()
    fresh()
    local remote = h.upstream()
    manifest({ { name = 'synchad.nvim', remote = remote } })
    sync(false)
    manifest({ { name = 'synchad.nvim', remote = remote }, { name = 'syncnew.nvim', remote = remote } })
    sync(false)
    h.eq(h.head(paths.install('syncnew.nvim')), h.head(remote))
    h.ok(loaded('syncnew.nvim'), 'the new plugin is not loaded')
    h.eq(_G.sync_configs, { ['synchad.nvim'] = 1, ['syncnew.nvim'] = 1 })
    h.ok(h.notified('Installing 1: syncnew.nvim'), vim.inspect(h.notes))
end)

test('sync lists the directories no spec owns and says how to delete them', function()
    fresh()
    local remote = h.upstream()
    installed('synckeep.nvim', remote)
    vim.fn.mkdir(paths.install('syncgone.nvim'), 'p')
    manifest({ { name = 'synckeep.nvim', remote = remote } })
    sync(false)
    h.ok(
        h.notified('1 not in your specs: syncgone.nvim. Run :Sarcina sync! to delete them.'),
        vim.inspect(h.notes)
    )
    h.eq(exists('syncgone.nvim'), true)
    h.ok(not h.notified('Everything is in sync'), vim.inspect(h.notes))
end)

test('sync! deletes them and installs what is missing in the same go', function()
    fresh()
    local remote = h.upstream()
    vim.fn.mkdir(paths.install('syncold.nvim'), 'p')
    manifest({ { name = 'syncfresh.nvim', remote = remote } })
    sync(true)
    h.eq({ exists('syncold.nvim'), exists('syncfresh.nvim') }, { false, true })
    h.ok(h.notified('Removed 1: syncold.nvim'), vim.inspect(h.notes))
    h.eq(_G.sync_configs, { ['syncfresh.nvim'] = 1 })
    -- The bang may come after the command too.
    vim.fn.mkdir(paths.install('syncold2.nvim'), 'p')
    vim.cmd('Sarcina! sync')
    h.eq(exists('syncold2.nvim'), false)
end)

test('with everything loaded and nothing extra, sync says so and runs nothing', function()
    fresh()
    local remote = h.upstream()
    manifest({ { name = 'syncdone.nvim', remote = remote } })
    sync(false)
    sync(false)
    h.ok(h.notified('Everything is in sync'), vim.inspect(h.notes))
    h.eq(_G.sync_configs, { ['syncdone.nvim'] = 1 })
end)

test('sync refuses a manifest with no plugins, and deletes nothing', function()
    fresh()
    manifest({})
    vim.fn.mkdir(paths.install('syncsafe.nvim'), 'p')
    sync(true)
    h.ok(h.notified('Not syncing: the manifest has no plugins'), vim.inspect(h.notes))
    h.eq(exists('syncsafe.nvim'), true)
end)

return tests
