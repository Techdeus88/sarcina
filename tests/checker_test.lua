local checker = require('sarcina.checker')
local h = require('helpers')
local paths = require('sarcina.paths')
local tasks = require('sarcina.tasks')
local ui = require('sarcina.ui')
local updater = require('sarcina.updater')
local window = require('sarcina.window')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

if vim.fn.executable('git') == 0 then return {} end

local function url(remote) return 'file://' .. remote end

-- A commit on `dir` with this subject and body, which changes its tracked file.
local function commit(dir, subject, body)
    vim.fn.writefile({ subject, tostring(vim.uv.hrtime()) }, dir .. '/tracked.txt')
    h.git(dir, 'add', '-A')
    local args = { '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', subject }
    if body then vim.list_extend(args, { '-m', body }) end
    h.git(dir, unpack(args))
end

-- `name`, installed from `remote` the way sarcina clones: shallow, into its install directory.
local function installed(name, remote)
    vim.fn.mkdir(paths.plugins_dir(), 'p')
    vim.fn.system({ 'git', 'clone', '-q', '--depth', '1', url(remote), paths.install(name) })
    return paths.install(name)
end

local function spec(name, remote, extra)
    return vim.tbl_extend(
        'force',
        { name = name, repo = url(remote), tasks = { h.lua('rtp', h.noop) } },
        extra or {}
    )
end

local function entry(name, remote, extra) return { name = name, spec = spec(name, remote, extra) } end

local function finished()
    h.ok(vim.wait(10000, function() return not checker.state().running end, 20), 'the check never ended')
end

local function check(entries)
    checker.run(entries)
    finished()
    return checker.state()
end

-- A plugin one commit behind, after a commit of its own that breaks something.
local function behind_by_three(name)
    local remote = h.upstream()
    local dir = installed(name, remote)
    commit(remote, 'fix: one')
    commit(remote, 'feat(jinja)!: update parser and queries')
    commit(remote, 'feat: two', 'BREAKING CHANGE: the option is gone')
    return remote, dir
end

local function buffer_lines() return vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false) end

local function details_text()
    return table.concat(vim.api.nvim_buf_get_lines(ui._detail_bufnr, 0, -1, false), '\n')
end

test(
    'a plugin that is behind is found with the commits in between, newest first, and which of them break',
    function()
        local remote, dir = behind_by_three('behind.nvim')
        local before = h.head(dir)
        local state = check({ entry('behind.nvim', remote) })
        local info = state.updates['behind.nvim']
        h.eq({ info.from, info.to }, { before, h.head(remote) })
        h.eq(vim.tbl_map(function(c) return { c.subject, c.breaking } end, info.commits), {
            { 'feat: two', true },
            { 'feat(jinja)!: update parser and queries', true },
            { 'fix: one', false },
        })
        h.eq(info.commits[1].sha, h.head(remote))
        -- Looking moves nothing.
        h.eq(h.head(dir), before)
        h.eq(h.git(dir, 'status', '--porcelain', '--untracked-files=no'), '')
        h.eq({ state.running, state.checked, state.total }, { false, 1, 1 })
    end
)

test('a plugin where its remote is, one with a dir and one not on disk are not listed', function()
    local remote = h.upstream()
    installed('current.nvim', remote)
    local state = check({
        entry('current.nvim', remote),
        entry('mine.nvim', remote, { dir = vim.fn.tempname() }),
        entry('absent.nvim', remote),
    })
    h.eq(state.updates, {})
    h.eq(state.total, 1)
end)

test('a pinned plugin is checked against its pin, not the tip of its branch', function()
    local remote = h.upstream()
    h.git(remote, 'tag', 'v1.0.0')
    installed('pinned.nvim', remote)
    h.git(installed('pinned.nvim', remote), 'checkout', '-q', 'v1.0.0')
    commit(remote, 'feat: after the tag')
    h.eq(check({ entry('pinned.nvim', remote, { tag = 'v1.0.0' }) }).updates, {})
    h.git(remote, 'tag', 'v1.1.0')
    local info = check({ entry('pinned.nvim', remote, { tag = 'v1.1.0' }) }).updates['pinned.nvim']
    h.eq(info.to, h.head(remote))
    h.eq(#info.commits, 1)
end)

test('a remote that cannot be reached is named as failed, and the others are still checked', function()
    local gone = h.upstream()
    installed('gone.nvim', gone)
    vim.fn.delete(gone, 'rf')
    local remote = behind_by_three('fine.nvim')
    local state = check({ entry('gone.nvim', gone), entry('fine.nvim', remote) })
    h.ok(state.failed['gone.nvim'], vim.inspect(state.failed))
    h.ok(state.updates['fine.nvim'], 'the reachable plugin was not checked')
end)

test('a check of some plugins keeps what the last check found for the others', function()
    local one = behind_by_three('one.nvim')
    local two = behind_by_three('two.nvim')
    check({ entry('one.nvim', one), entry('two.nvim', two) })
    checker.run({ entry('one.nvim', one) }, nil, { keep = true })
    finished()
    h.ok(checker.update_of('two.nvim'), 'the other plugin was forgotten')
    h.ok(checker.update_of('one.nvim'))
    -- Only a check of every plugin spares the window the next one.
    h.eq(checker.fresh(), false)
end)

test(
    'the list shows a section per timing, in the order now, later, triggered, each with its count',
    function()
        h.register({
            { name = 'n1', timing = 'now' },
            { name = 'l1' },
            { name = 't1', timing = 'trigger' },
            { name = 'l2' },
        })
        -- Flat ends: the rounded ones are glyphs a diff of the lines does not show.
        window.rounded = false
        ui.open()
        window.rounded = true
        h.eq(buffer_lines(), {
            ' Now (1)',
            '   n1 now  0/0  tasks …  pending',
            '',
            ' Later (2)',
            '   l1 later  0/0  tasks …  pending',
            '   l2 later  0/0  tasks …  pending',
            '',
            ' Triggered (1)',
            '   t1 trigger  0/0  tasks …  pending',
        })
        h.eq(window.entry_at(1), { kind = 'section' })
        h.eq(window.entry_at(3), { kind = 'blank' })
    end
)

test('while a check runs the Updates section says checking, and then lists each update', function()
    local remote = behind_by_three('upd.nvim')
    h.register({ spec('upd.nvim', remote), { name = 'other' } })
    window.rounded = false
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    checker.run()
    ui._flush()
    h.eq(buffer_lines()[1], ' Updates (0)  ↻ checking…')
    finished()
    ui._flush()
    local lines = buffer_lines()
    h.eq(lines[1], ' Updates (1)  <CR> changelog')
    h.eq(
        lines[2],
        '   ↑ upd.nvim ' .. h.head(remote):sub(1, 7) .. ' feat: two · 3 commits behind  △ 2 breaking'
    )
    h.eq(lines[3], '')
    h.eq(window.entry_at(2), { kind = 'update', name = 'upd.nvim' })
    -- The cursor moves onto an update, and the details show that plugin.
    vim.api.nvim_win_set_cursor(ui._winid, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
    h.eq(window.selected(), 'upd.nvim')
    h.ok(details_text():find('update%s+%x+ · 3 commits behind  △ 2 breaking'), details_text())
    window.rounded = true
end)

test('a check that found nothing says up to date, and one with nothing to check shows no section', function()
    local remote = h.upstream()
    installed('fresh.nvim', remote)
    h.register({ spec('fresh.nvim', remote) })
    ui.open()
    check()
    ui._flush()
    h.eq(buffer_lines()[1], ' Updates (0)  ✔ up to date')
    checker._reset()
    h.register({ { name = 'nothing' } })
    check()
    ui._flush()
    h.eq(buffer_lines()[1], ' Later (1)')
end)

test('enter shows the changelog of an update in the details, and enter again shows the tasks', function()
    local remote = behind_by_three('log.nvim')
    h.register({ spec('log.nvim', remote) })
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    check()
    ui._flush()
    vim.api.nvim_set_current_win(ui._winid)
    vim.api.nvim_win_set_cursor(ui._winid, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'xt', false)
    local text = details_text()
    h.ok(
        text:find(
            'Changelog\n △ %x+ feat: two\n △ %x+ feat%(jinja%)!: update parser and queries\n   %x+ fix: one'
        ),
        text
    )
    h.ok(not text:find('Tasks', 1, true), text)
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'xt', false)
    h.ok(details_text():find('Tasks', 1, true), details_text())
end)

test(
    'the window looks for updates when it opens, not again a moment later, and not at all when that is off',
    function()
        local remote = behind_by_three('auto.nvim')
        h.register({ spec('auto.nvim', remote) })
        ui.check_on_open = true
        ui.open()
        h.eq(checker.state().running, true)
        finished()
        local first = checker.state()
        ui.close()
        ui.open()
        h.ok(checker.state() == first, 'a check that just finished ran again')
        ui.close()
        checker._reset()
        ui.check_on_open = false
        ui.open()
        h.eq({ checker.state().running, checker.state().total }, { false, 0 })
    end
)

test('a window that opens during a run looks for updates once the run is done', function()
    local remote = h.upstream()
    installed('later.nvim', remote)
    local release
    require('sarcina.executors').c_hold = function(_, done)
        release = function() done(true) end
    end
    h.register({ spec('later.nvim', remote) })
    ui.check_on_open = true
    tasks.enqueue('later.nvim', { tasks = { { id = 'install', type = 'c_hold' } } })
    tasks.run_all()
    h.ok(vim.wait(500, function() return release ~= nil end))
    ui.open()
    h.eq(checker.state().running, false)
    release()
    h.ok(tasks.wait(2000))
    h.ok(vim.wait(2000, function() return checker.state().total == 1 end), 'no check after the run')
    finished()
end)

test(':Sarcina check lists the updates in the window and says which plugins have one', function()
    local remote = behind_by_three('cmd.nvim')
    local resolved = { { name = 'cmd.nvim', timing = 'later', spec = spec('cmd.nvim', remote) } }
    updater.look(resolved, {})
    h.ok(h.notified('Checking 1 plugin...'), vim.inspect(h.notes))
    finished()
    h.ok(checker.update_of('cmd.nvim'), 'the update was not found')
    local info = checker.update_of('cmd.nvim')
    h.ok(
        h.notified(
            string.format(
                '1 update available: cmd.nvim %s → %s. Run :Sarcina update.',
                info.from:sub(1, 7),
                info.to:sub(1, 7)
            )
        ),
        vim.inspect(h.notes)
    )
    h.eq(tasks.snapshot().total, 0) -- the task list is left alone
end)

return tests
