local h = require('helpers')
local installer = require('sarcina.installer')
local installs = require('sarcina.installs')
local lock = require('sarcina.lock')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function specs_dir()
    local dir = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(dir, 'p')
    return dir
end

-- The manifest is exactly the plugins `names`, and nothing else in the specs directory.
local function manifest(names)
    for _, file in ipairs(vim.fn.glob(specs_dir() .. '/*.lua', false, true)) do
        vim.fn.delete(file)
    end
    local lines = { 'return {' }
    for _, name in ipairs(names) do
        table.insert(lines, string.format("    { name = '%s', repo = 'x/%s' },", name, name))
    end
    table.insert(lines, '}')
    vim.fn.writefile(lines, specs_dir() .. '/clean_test.lua')
end

-- The plugins directory of the throwaway data directory, empty, so only what a test makes is in it.
local function empty_plugins_dir()
    vim.fn.delete(paths.plugins_dir(), 'rf')
    vim.fn.mkdir(paths.plugins_dir(), 'p')
end

local function plugin_dir(name)
    vim.fn.mkdir(paths.install(name), 'p')
    return paths.install(name)
end

local function exists(name) return vim.uv.fs_stat(paths.install(name)) ~= nil end

local function entries(names)
    return vim.tbl_map(function(name) return { name = name } end, names)
end

local function clean(bang)
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina clean' .. (bang and '!' or ''))
end

test('stale lists the directories no plugin owns, sorted, and ignores files', function()
    empty_plugins_dir()
    plugin_dir('cl-b.nvim')
    plugin_dir('cl-a.nvim')
    plugin_dir('cl-keep.nvim')
    vim.fn.writefile({ 'a file, not a plugin' }, paths.plugins_dir() .. 'cl-notes.txt')
    h.eq(installer.stale(entries({ 'cl-keep.nvim' })), { 'cl-a.nvim', 'cl-b.nvim' })
    vim.fn.delete(paths.plugins_dir() .. 'cl-notes.txt')
end)

test('stale ignores the staging directory', function()
    empty_plugins_dir()
    plugin_dir('cl-a.nvim')
    plugin_dir('.staging')
    h.eq(installer.stale(entries({})), { 'cl-a.nvim' })
end)

test('clean only lists them, and says how to delete them', function()
    empty_plugins_dir()
    manifest({ 'clkeep.nvim' })
    plugin_dir('clkeep.nvim')
    plugin_dir('clgone.nvim')
    clean(false)
    h.ok(
        h.notified('1 not in your specs: clgone.nvim. Run :Sarcina clean! to delete them.'),
        vim.inspect(h.notes)
    )
    h.eq({ exists('clkeep.nvim'), exists('clgone.nvim') }, { true, true })
end)

test(
    'clean! deletes them, and forgets them in the runtimepath, the install times and the lock file',
    function()
        manifest({ 'clkeep.nvim' })
        plugin_dir('clkeep.nvim')
        local gone = plugin_dir('clgone.nvim')
        plugin_dir('clgone2.nvim')
        vim.opt.rtp:append(gone)
        installs.record('clgone.nvim', 10)
        installs.record('clkeep.nvim', 20)
        vim.fn.mkdir(vim.fs.dirname(paths.lock_file()), 'p')
        vim.fn.writefile({
            vim.json.encode({ ['clgone.nvim'] = { commit = 'aaa' }, ['clkeep.nvim'] = { commit = 'bbb' } }),
        }, paths.lock_file())
        lock._reset()
        clean(true)
        h.eq({ exists('clkeep.nvim'), exists('clgone.nvim'), exists('clgone2.nvim') }, { true, false, false })
        h.ok(h.notified('Removed 2: clgone.nvim, clgone2.nvim'), vim.inspect(h.notes))
        h.ok(not vim.tbl_contains(vim.opt.rtp:get(), gone), 'the removed plugin is still on the runtimepath')
        installs._reset()
        lock._reset()
        h.eq({ installs.get('clgone.nvim'), lock.get('clgone.nvim') }, {})
        h.eq({ installs.get('clkeep.nvim').ms, lock.get('clkeep.nvim') }, { 20, 'bbb' })
    end
)

test('the bang may come after clean or after the command', function()
    empty_plugins_dir()
    manifest({ 'clbang.nvim' })
    plugin_dir('clbang.nvim')
    plugin_dir('clbang1.nvim')
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina! clean')
    h.eq({ exists('clbang.nvim'), exists('clbang1.nvim') }, { true, false })
    plugin_dir('clbang2.nvim')
    vim.cmd('Sarcina clean!')
    h.eq({ exists('clbang.nvim'), exists('clbang2.nvim') }, { true, false })
end)

test('with nothing to remove clean says so', function()
    empty_plugins_dir()
    manifest({ 'clonly.nvim' })
    plugin_dir('clonly.nvim')
    clean(true)
    h.ok(h.notified('Nothing to clean'), vim.inspect(h.notes))
end)

test(
    'clean refuses a manifest with no plugins, so a spec that failed to load cannot empty the directory',
    function()
        manifest({})
        plugin_dir('clsafe.nvim')
        clean(true)
        h.ok(h.notified('Not cleaning: the manifest has no plugins'), vim.inspect(h.notes))
        h.eq(exists('clsafe.nvim'), true)
    end
)

test('remove deletes a directory even when it is a link, never what the link points at', function()
    empty_plugins_dir()
    local target = vim.fn.tempname()
    vim.fn.mkdir(target, 'p')
    vim.fn.writefile({ 'precious' }, target .. '/file.txt')
    vim.fn.mkdir(vim.fs.dirname(paths.install('cllink.nvim')), 'p')
    vim.uv.fs_symlink(target, paths.install('cllink.nvim'))
    h.eq(installer.stale(entries({})), { 'cllink.nvim' })
    local removed = installer.remove({ 'cllink.nvim' })
    h.eq(removed, { 'cllink.nvim' })
    h.eq(vim.fn.readfile(target .. '/file.txt'), { 'precious' })
end)

local function ask_with(answer)
    local confirm = require('sarcina.confirm')
    local ask, prompts = confirm.ask, {}
    confirm.enabled = true
    confirm.ask = function(prompt, callback)
        table.insert(prompts, prompt)
        callback(answer)
    end
    return prompts, function()
        confirm.ask, confirm.enabled = ask, false
    end
end

test(
    'remove deletes several named plugins in one batch, warning about the ones still in the specs',
    function()
        empty_plugins_dir()
        manifest({ 'rmkept.nvim' })
        plugin_dir('rmkept.nvim')
        plugin_dir('rmgone.nvim')
        local prompts, restore = ask_with(true)
        vim.cmd('runtime plugin/sarcina.lua')
        vim.cmd('Sarcina delete rmkept.nvim rmgone.nvim')
        restore()
        h.eq(#prompts, 1)
        h.ok(prompts[1]:find('Delete 2 plugins', 1, true), prompts[1])
        h.ok(prompts[1]:find('installs again at the next startup: rmkept.nvim', 1, true), prompts[1])
        h.ok(not prompts[1]:find('startup: rmgone', 1, true), prompts[1])
        h.eq(exists('rmkept.nvim'), false)
        h.eq(exists('rmgone.nvim'), false)
        h.ok(h.notified('Deleted 2: rmkept.nvim, rmgone.nvim'), vim.inspect(h.notes))
    end
)

test('delete keeps the directory on no, and names a plugin that is not installed', function()
    empty_plugins_dir()
    manifest({})
    plugin_dir('rmno.nvim')
    local _, restore = ask_with(false)
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina delete rmno.nvim nothere.nvim')
    restore()
    h.eq(exists('rmno.nvim'), true)
    h.ok(h.notified('Not installed: nothere.nvim'), vim.inspect(h.notes))
    h.ok(h.notified('Nothing deleted'), vim.inspect(h.notes))
end)

test('delete runs without a question when confirm is off', function()
    empty_plugins_dir()
    manifest({})
    plugin_dir('rmquiet.nvim')
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina delete rmquiet.nvim')
    h.eq(exists('rmquiet.nvim'), false)
end)

test('delete takes the plugin out of the session at once: no row, no count, no jobs', function()
    empty_plugins_dir()
    manifest({ 'rmrow.nvim', 'rmstay.nvim' })
    plugin_dir('rmrow.nvim')
    plugin_dir('rmstay.nvim')
    local plugins = {
        { name = 'rmrow.nvim', tasks = { h.lua('rtp', h.noop) } },
        { name = 'rmstay.nvim', tasks = { h.lua('rtp', h.noop) } },
    }
    h.register(plugins)
    h.run(plugins)
    local stats = require('sarcina.stats')
    h.eq(stats.get().count, 2)
    vim.cmd('runtime plugin/sarcina.lua')
    vim.cmd('Sarcina delete rmrow.nvim')
    h.eq(stats.plugin('rmrow.nvim'), nil)
    h.eq(h.names(stats.plugins()), { 'rmstay.nvim' })
    h.eq(stats.get().count, 1)
    h.eq(#require('sarcina.track').jobs_of('rmrow.nvim'), 0)
    h.eq(require('sarcina.tasks').plugin_failed('rmrow.nvim'), false)
    manifest({})
end)

return tests
