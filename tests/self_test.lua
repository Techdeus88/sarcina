local checker = require('sarcina.checker')
local confirm = require('sarcina.confirm')
local executors = require('sarcina.executors')
local h = require('helpers')
local installer = require('sarcina.installer')
local paths = require('sarcina.paths')
local self = require('sarcina.self')
local stats = require('sarcina.stats')
local tasks = require('sarcina.tasks')
local ui = require('sarcina.ui')
local updater = require('sarcina.updater')
local window = require('sarcina.window')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

if vim.fn.executable('git') == 0 then return {} end

local function commit(dir, subject)
    vim.fn.writefile({ subject, tostring(vim.uv.hrtime()) }, dir .. '/tracked.txt')
    h.git(dir, 'add', '-A')
    h.git(dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', subject)
end

-- Sarcina as a full clone of a remote that is `ahead` commits further, all of them released to `stable`, in the
-- plugins directory as a bootstrap puts it. Returns the remote and the clone.
local function own_checkout(ahead)
    local remote = h.upstream()
    local dir = paths.plugins_dir() .. 'sarcina'
    vim.fn.mkdir(paths.plugins_dir(), 'p')
    vim.fn.system({ 'git', 'clone', '-q', 'file://' .. remote, dir })
    for i = 1, ahead do
        commit(remote, 'feat: sarcina ' .. i)
    end
    h.git(remote, 'branch', '-f', 'stable')
    self.root = dir
    return remote, dir
end

local function subjects(info)
    return vim.tbl_map(function(c) return c.subject end, info and info.commits or {})
end

local function finished()
    h.ok(vim.wait(10000, function() return not checker.state().running end, 20))
end

-- What a check of everything finds for Sarcina, from a fresh start.
local function own_update()
    checker._reset()
    checker.run()
    finished()
    return checker.update_of('sarcina')
end

test('Sarcina runs from the repository its files are in', function()
    self.root = nil
    local dir = self.dir()
    h.ok(vim.uv.fs_stat(dir .. '/lua/sarcina/self.lua'), dir)
    h.eq(self.is(dir), true)
    h.eq(self.is(vim.fn.tempname()), false)
end)

test('clean and delete never take Sarcina in the plugins directory for a plugin', function()
    vim.fn.delete(paths.plugins_dir(), 'rf')
    own_checkout(0)
    vim.fn.mkdir(paths.install('forgotten.nvim'), 'p')
    h.eq(installer.installed(), { 'forgotten.nvim' })
    h.eq(installer.stale({}), { 'forgotten.nvim' })
end)

test('a check of everything looks at Sarcina first, alone, and then at the plugins', function()
    local _, dir = own_checkout(2)
    local plugin_remote = h.upstream()
    vim.fn.system({
        'git',
        'clone',
        '-q',
        '--depth',
        '1',
        'file://' .. plugin_remote,
        paths.install('dep.nvim'),
    })
    commit(plugin_remote, 'fix: dep')
    h.register({ { name = 'dep.nvim', repo = 'file://' .. plugin_remote } })
    local order, own_pending, overlapped = {}, false, false
    local look_ahead = executors.look_ahead
    executors.look_ahead = function(at, pin, cb)
        table.insert(order, at)
        if own_pending then overlapped = true end
        local own = at == dir
        own_pending = own
        look_ahead(at, pin, function(...)
            if own then own_pending = false end
            cb(...)
        end)
    end
    local ok, err = pcall(function()
        checker.run()
        finished()
    end)
    executors.look_ahead = look_ahead
    assert(ok, err)
    h.eq(order, { dir, paths.install('dep.nvim') })
    h.eq(overlapped, false)
    local own = checker.update_of('sarcina')
    h.eq(vim.tbl_map(function(c) return c.subject end, own.commits), { 'feat: sarcina 2', 'feat: sarcina 1' })
    h.ok(checker.update_of('dep.nvim'), 'the plugin was not checked')
    -- A full clone stays full: looking ahead does not cut its history.
    h.eq(h.git(dir, 'rev-parse', '--is-shallow-repository'), 'false')
end)

test(
    "the window leads the Updates list with Sarcina's own update, and its details show what it brings",
    function()
        local remote = own_checkout(1)
        h.register({ { name = 'a', tasks = { h.lua('rtp', h.noop) } } })
        vim.o.columns, vim.o.lines = 200, 50
        ui.open()
        checker.run()
        finished()
        ui._flush()
        local lines = vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false)
        h.ok(
            lines[3]:find(
                '↑ sarcina ' .. h.head(remote):sub(1, 7) .. ' feat: sarcina 1 · 1 commit behind',
                1,
                true
            ),
            lines[3]
        )
        h.eq(window.entry_at(3), { kind = 'update', name = 'sarcina' })
        vim.api.nvim_set_current_win(ui._winid)
        vim.api.nvim_win_set_cursor(ui._winid, { 3, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
        h.eq(window.selected(), 'sarcina')
        local text = table.concat(vim.api.nvim_buf_get_lines(ui._detail_bufnr, 0, -1, false), '\n')
        h.ok(text:find('state%s+↑ update available'), text)
        h.ok(text:find('Changelog\n   %x+ feat: sarcina 1'), text)
        -- A redraw keeps the cursor and the details on it.
        ui._full = true
        ui._flush()
        h.eq(window.selected(), 'sarcina')
    end
)

test('update moves Sarcina to its remote like a plugin, and it takes no row in the window', function()
    local remote, dir = own_checkout(1)
    h.register({ { name = 'a', tasks = { h.lua('rtp', h.noop) } } })
    updater.update({}, { 'sarcina' })
    h.ok(tasks.wait(15000), 'the update did not finish')
    h.eq(h.head(dir), h.head(remote))
    h.eq(stats.plugin('sarcina'), nil)
    h.ok(h.notified('Updated Sarcina: sarcina '), vim.inspect(h.notes))
end)

-- Sarcina one commit behind and the plugin `name` one commit behind, both cloned. Returns what to hand the updater.
local function own_and_plugin(name)
    own_checkout(1)
    local remote = h.upstream()
    vim.fn.system({ 'git', 'clone', '-q', '--depth', '1', 'file://' .. remote, paths.install(name) })
    commit(remote, 'fix: ' .. name)
    local resolved = require('sarcina.resolver').resolve({ { name = name, repo = 'file://' .. remote } })
    h.register({ { name = name, tasks = { h.lua('rtp', h.noop) } } })
    return resolved
end

test('the messages count your plugins and name Sarcina apart, since it is none of them', function()
    local resolved = own_and_plugin('counted.nvim')
    updater.check(resolved)
    h.ok(tasks.wait(15000), 'the check did not finish')
    h.ok(h.notified('Checking Sarcina and 1 plugin...'), vim.inspect(h.notes))
    h.ok(not h.notified('2 plugins'), vim.inspect(h.notes))
    updater.look(resolved)
    finished()
    h.ok(h.notified('Checking Sarcina and 1 plugin...'), vim.inspect(h.notes))
    local asked
    local ask, enabled = confirm.ask, confirm.enabled
    confirm.enabled, confirm.ask = true, function(prompt) asked = prompt end
    local ok, err = pcall(function()
        updater.update(resolved)
        h.ok(tasks.wait(15000), 'the check did not finish')
    end)
    confirm.enabled, confirm.ask = enabled, ask
    assert(ok, err)
    h.ok(vim.startswith(asked or '', 'Update Sarcina and 1 plugin?\n'), asked)
    h.notes = {}
    ui._messages = h.notes
    updater.update(resolved, { 'counted.nvim' })
    h.ok(tasks.wait(15000), 'the update did not finish')
    h.ok(h.notified('Updating 1 plugin...'), vim.inspect(h.notes))
    h.ok(h.notified('Updated 1 plugin: counted.nvim'), vim.inspect(h.notes))
    h.ok(h.notified('Restart Neovim to load it.'), vim.inspect(h.notes))
end)

test('the progress in the header counts your plugins and adds Sarcina apart', function()
    local resolved = own_and_plugin('held.nvim')
    local look_ahead = executors.look_ahead
    local release
    executors.look_ahead = function(at, pin, cb)
        if at == self.root then return look_ahead(at, pin, cb) end
        release = function() look_ahead(at, pin, cb) end
    end
    vim.o.columns, vim.o.lines = 200, 50
    local ok, err = pcall(function()
        ui.open()
        updater.look(resolved)
        h.ok(vim.wait(5000, function() return release ~= nil end, 20), 'the plugin was never looked at')
        ui._full = true
        ui._flush()
        local first = vim.api.nvim_buf_get_lines(ui._header_bufnr, 0, 1, false)[1]
        h.ok(first:find('↻ Checking for updates 0/1 plugin + Sarcina', 1, true), first)
        release()
        finished()
    end)
    executors.look_ahead = look_ahead
    assert(ok, err)
end)

test('without a pin Sarcina follows stable, the latest release, and not what main has past it', function()
    local remote, dir = own_checkout(1)
    local released = h.git(remote, 'rev-parse', 'stable')
    commit(remote, 'feat: unreleased')
    local own = own_update()
    h.eq(subjects(own), { 'feat: sarcina 1' })
    h.eq(own.to, released)
    h.register({ { name = 'a', tasks = { h.lua('rtp', h.noop) } } })
    updater.update({}, { 'sarcina' })
    h.ok(tasks.wait(15000), 'the update did not finish')
    h.eq(h.head(dir), released)
end)

test('a pin takes Sarcina to that tag, to the newest version that matches, or to main', function()
    local remote, dir = own_checkout(0)
    local main = h.git(remote, 'branch', '--show-current')
    commit(remote, 'feat: one')
    h.git(remote, 'tag', 'v1.0.0')
    commit(remote, 'feat: two')
    h.git(remote, 'tag', 'v1.1.0')
    commit(remote, 'feat: three')
    self.pin = { tag = 'v1.0.0' }
    h.eq(subjects(own_update()), { 'feat: one' })
    self.pin = { version = '1.*' }
    h.eq(subjects(own_update()), { 'feat: two', 'feat: one' })
    self.pin = { branch = main }
    h.eq(subjects(own_update()), { 'feat: three', 'feat: two', 'feat: one' })
    self.pin = { version = '1.*' }
    h.register({ { name = 'a', tasks = { h.lua('rtp', h.noop) } } })
    updater.update({}, { 'sarcina' })
    h.ok(tasks.wait(15000), 'the update did not finish')
    h.eq(h.head(dir), h.git(remote, 'rev-parse', 'v1.1.0^{commit}'))
end)

test('the details of an update of Sarcina say what it follows', function()
    local remote = own_checkout(1)
    h.git(remote, 'tag', 'v9.9.9')
    self.pin = { tag = 'v9.9.9' }
    h.register({ { name = 'a', tasks = { h.lua('rtp', h.noop) } } })
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    own_update()
    ui._flush()
    vim.api.nvim_set_current_win(ui._winid)
    vim.api.nvim_win_set_cursor(ui._winid, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
    local text = table.concat(vim.api.nvim_buf_get_lines(ui._detail_bufnr, 0, -1, false), '\n')
    h.ok(text:find('pin%s+tag v9.9.9'), text)
end)

test('with no git checkout to look at, there is no self-check', function()
    self.root = vim.fn.tempname()
    vim.fn.mkdir(self.root, 'p')
    h.eq(self.entry(), nil)
    self.root = false
    h.eq({ self.dir(), self.entry() }, {})
end)

return tests
