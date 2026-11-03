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

-- Whether the details carry the `update` line of a plugin that has an update, and not a task named update.
local function shows_update() return details_text():find('\nupdate%s+%x+ ·') ~= nil end

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
    'the list is one run of plugins, now then later then triggered, each in load order, with no headers',
    function()
        h.register({
            { name = 'n1', timing = 'now' },
            { name = 'l1' },
            { name = 't1', timing = 'trigger' },
            { name = 'l2' },
            { name = 'n2', timing = 'now' },
        })
        -- Flat ends: the rounded ones are glyphs a diff of the lines does not show.
        window.rounded = false
        ui.open()
        window.rounded = true
        -- A blank line above the content and below it keeps it off the borders, and none between the rows.
        h.eq(buffer_lines(), {
            '',
            '   n1 now  0/0  tasks …  pending',
            '   n2 now  0/0  tasks …  pending',
            '   l1 later  0/0  tasks …  pending',
            '   l2 later  0/0  tasks …  pending',
            '   t1 trigger  0/0  tasks …  pending',
            '',
        })
        h.eq(window.entry_at(1), { kind = 'blank' })
        h.eq(window.entry_at(2), { kind = 'plugin', name = 'n1' })
        h.eq(window.entry_at(7), { kind = 'blank' })
    end
)

test('a check adds no line to the list, and the plugin with an update shows it in its details', function()
    local remote = behind_by_three('upd.nvim')
    h.register({ spec('upd.nvim', remote), { name = 'other' } })
    window.rounded = false
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    h.eq(window.selected(), 'upd.nvim')
    h.eq(shows_update(), false)
    checker.run()
    ui._flush()
    finished()
    ui._flush()
    -- The list is the rows of the plugins between its two blank lines: no heading, no row for the update.
    local lines = buffer_lines()
    h.eq(#lines, 4)
    h.eq(lines[1], '')
    h.ok(lines[2]:find('^   upd%.nvim'), lines[2])
    h.ok(lines[3]:find('^   other'), lines[3])
    h.eq(lines[4], '')
    h.eq(table.concat(lines, '\n'):find('Updates', 1, true), nil)
    h.eq(window.entry_at(2), { kind = 'plugin', name = 'upd.nvim' })
    -- The details of the selected plugin took the update without the cursor moving.
    h.ok(details_text():find('update%s+%x+ · 3 commits behind  △ 2 breaking'), details_text())
    -- Another plugin shows none.
    vim.api.nvim_win_set_cursor(ui._winid, { 3, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
    h.eq(window.selected(), 'other')
    h.eq(shows_update(), false)
    window.rounded = true
end)

test('after a check the row of a plugin that is behind says so, and the other rows do not change', function()
    local remote = behind_by_three('news.nvim')
    h.register({ spec('news.nvim', remote), { name = 'other' } })
    window.rounded = false
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    local others = buffer_lines()[window.line('other')]
    local before = buffer_lines()[window.line('news.nvim')]
    h.ok(not before:find('↑', 1, true), before)
    check()
    ui._flush()
    local row = buffer_lines()[window.line('news.nvim')]
    h.ok(row:find('↑ ' .. h.head(remote):sub(1, 7) .. ' · 3 commits behind  △ 2 breaking', 1, true), row)
    h.eq(buffer_lines()[window.line('other')], others)
    local stats_row = require('sarcina.stats').plugin('news.nvim')
    h.eq({ stats_row.update.to, stats_row.changed }, { h.head(remote), nil })
    window.rounded = true
end)

test('an update with nothing to do leaves the row exactly as it was', function()
    local remote = h.upstream()
    installed('steady.nvim', remote)
    local plugin = spec('steady.nvim', remote, { tasks = { h.lua('load', h.noop), h.lua('rtp', h.noop) } })
    h.register({ plugin })
    h.run({ plugin })
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    local before = buffer_lines()[window.line('steady.nvim')]
    h.ok(before:find('2/2', 1, true), before)
    updater.update({ { name = 'steady.nvim', timing = 'later', spec = plugin } }, {})
    h.ok(tasks.wait(15000), 'the update did not finish')
    ui._flush()
    h.eq(buffer_lines()[window.line('steady.nvim')], before)
end)

test('a check that found nothing leaves the row exactly as it was', function()
    local remote = h.upstream()
    installed('same.nvim', remote)
    local plugin = spec('same.nvim', remote, { tasks = { h.lua('load', h.noop), h.lua('rtp', h.noop) } })
    h.register({ plugin })
    h.run({ plugin })
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    local before = buffer_lines()[window.line('same.nvim')]
    check()
    ui._flush()
    h.eq(buffer_lines()[window.line('same.nvim')], before)
end)

test('a row with news is cut to the width of the list and keeps its news first', function()
    local remote = behind_by_three('narrow.nvim')
    h.register({ spec('narrow.nvim', remote) })
    vim.o.columns, vim.o.lines = 80, 24
    ui.open()
    check()
    ui._flush()
    local row = buffer_lines()[window.line('narrow.nvim')]
    h.ok(vim.fn.strdisplaywidth(row) <= vim.api.nvim_win_get_config(ui._winid).width, row)
    h.ok(row:find('↑', 1, true), 'the update was cut before anything else: ' .. row)
end)

test(
    'while its remote is asked a plugin row says checking, and after the check it is back as it was',
    function()
        local remote = behind_by_three('row.nvim')
        h.register({ spec('row.nvim', remote) })
        local stats = require('sarcina.stats')
        local before = stats.plugin('row.nvim').state
        ui.open()
        checker.run()
        h.eq(checker.state().looking['row.nvim'], true)
        h.eq(stats.plugin('row.nvim').state, 'checking')
        ui._flush()
        local line = buffer_lines()[window.line('row.nvim')]
        h.ok(line:find('▶', 1, true) and line:find('checking for updates…', 1, true), line)
        finished()
        h.eq(checker.state().looking, {})
        h.eq(stats.plugin('row.nvim').state, before)
    end
)

test('a check that found nothing leaves the list as it was and gives the details no update', function()
    local remote = h.upstream()
    installed('fresh.nvim', remote)
    h.register({ spec('fresh.nvim', remote) })
    vim.o.columns, vim.o.lines = 200, 50
    ui.open()
    local before = buffer_lines()
    check()
    ui._flush()
    h.eq(buffer_lines(), before)
    h.eq(shows_update(), false)
    checker._reset()
    h.register({ { name = 'nothing' } })
    check()
    ui._flush()
    h.ok(buffer_lines()[2]:find('^   nothing'), buffer_lines()[2])
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

test(
    'an update that moved a plugin has no update left to show, and one that left it alone keeps it',
    function()
        local moved = behind_by_three('moved.nvim')
        local kept, kept_dir = behind_by_three('kept.nvim')
        vim.fn.writefile({ 'a change of my own' }, kept_dir .. '/tracked.txt')
        local resolved = {
            { name = 'moved.nvim', timing = 'later', spec = spec('moved.nvim', moved) },
            { name = 'kept.nvim', timing = 'later', spec = spec('kept.nvim', kept) },
        }
        h.register(vim.tbl_map(function(e) return e.spec end, resolved))
        vim.o.columns, vim.o.lines = 200, 50
        ui.open()
        check()
        h.eq(vim.tbl_count(checker.state().updates), 2)
        updater.update(resolved, {})
        h.ok(tasks.wait(15000), 'the update did not finish')
        h.ok(
            vim.wait(1000, function() return checker.update_of('moved.nvim') == nil end),
            'the moved plugin is still listed'
        )
        h.ok(checker.update_of('kept.nvim'), 'a plugin left alone lost its update')
        ui._flush()
        -- The rows say what happened: one moved, no longer behind; one left alone, still behind.
        local moved_row = buffer_lines()[window.line('moved.nvim')]
        h.ok(moved_row:find('updated %x+ → %x+') and not moved_row:find('↑', 1, true), moved_row)
        local kept_row = buffer_lines()[window.line('kept.nvim')]
        h.ok(
            kept_row:find('update skipped: local changes', 1, true) and kept_row:find('↑', 1, true),
            kept_row
        )
        local function details_of(name)
            vim.api.nvim_win_set_cursor(ui._winid, { window.line(name), 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui._bufnr })
            return details_text()
        end
        details_of('moved.nvim')
        h.eq(shows_update(), false)
        h.ok(details_of('kept.nvim'):find('update%s+%x+ · 3 commits behind'), details_text())
    end
)

return tests
