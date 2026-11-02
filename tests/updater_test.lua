local h = require('helpers')
local installs = require('sarcina.installs')
local lock = require('sarcina.lock')
local paths = require('sarcina.paths')
local resolver = require('sarcina.resolver')
local stats = require('sarcina.stats')
local tasks = require('sarcina.tasks')
local updater = require('sarcina.updater')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

if vim.fn.executable('git') == 0 then return {} end

local git, head, advance, upstream = h.git, h.head, h.advance, h.upstream

-- The plugin `name`, cloned from `remote` the way sarcina does: shallow, into its install directory.
local function clone(remote, name)
    vim.fn.mkdir(vim.fs.dirname(paths.install(name)), 'p')
    vim.fn.system({ 'git', 'clone', '-q', '--depth', '1', 'file://' .. remote, paths.install(name) })
    return paths.install(name)
end

-- Pretend the plugin was built at its current commit, as an earlier run would have.
local function built_at_head(name)
    vim.fn.writefile({ head(paths.install(name)) }, paths.install(name) .. '/.git/sarcina-build')
end

local function resolved(specs) return resolver.resolve(specs) end

local function finish() h.ok(tasks.wait(15000), 'the run did not finish') end

-- Waits for the lock file to say `commit` for `name`.
local function locked(name, commit)
    return vim.wait(3000, function()
        lock._reset()
        return lock.get(name) == commit
    end, 20)
end

test('check reports an update without moving the plugin', function()
    local remote = upstream()
    local dir = clone(remote, 'upchk.nvim')
    local before = head(dir)
    advance(remote)
    updater.check(resolved({ { name = 'upchk.nvim', repo = remote } }))
    finish()
    h.ok(
        h.job('upchk.nvim', 'check').note:find('^update available %x+ → %x+$'),
        h.job('upchk.nvim', 'check').note
    )
    h.eq(head(dir), before)
    h.ok(h.notified('1 update available: upchk.nvim'), vim.inspect(h.notes))
    h.ok(h.notified('Run :Sarcina update.'))
    h.eq(vim.uv.fs_stat(paths.lock_file()), nil) -- a check changes nothing, so it keeps no lock
end)

test('update moves the plugin to the remote, rebuilds it once, and writes the lock file', function()
    local remote = upstream()
    local dir = clone(remote, 'upmove.nvim')
    local old = head(dir)
    built_at_head('upmove.nvim')
    advance(remote)
    local ran = 0
    updater.update(
        resolved({ { name = 'upmove.nvim', repo = remote, build = function() ran = ran + 1 end } })
    )
    finish()
    h.eq(head(dir), head(remote))
    h.ok(head(dir) ~= old)
    h.eq(ran, 1)
    h.eq(h.job('upmove.nvim', 'build').status, 'done')
    h.ok(locked('upmove.nvim', head(remote)), 'the lock file does not name the new commit')
    h.eq(installs.get('upmove.nvim'), nil) -- an update is not an install
    h.ok(h.notified('Updated 1 plugin: upmove.nvim'), vim.inspect(h.notes))
    h.ok(h.notified('Restart Neovim'))
end)

test('a plugin that has not moved is up to date, and is not rebuilt', function()
    local remote = upstream()
    local dir = clone(remote, 'upsame.nvim')
    built_at_head('upsame.nvim')
    local ran = 0
    updater.update(
        resolved({ { name = 'upsame.nvim', repo = remote, build = function() ran = ran + 1 end } })
    )
    finish()
    h.eq(h.job('upsame.nvim', 'update').note, 'up to date')
    h.eq(h.job('upsame.nvim', 'build').note, 'up to date')
    h.eq(ran, 0)
    h.eq(head(dir), head(remote))
    h.ok(h.notified('Everything is up to date.'))
    h.ok(locked('upsame.nvim', head(dir)), 'an update fills in the lock file for a plugin that did not move')
end)

test('a plugin with changes of its own is left alone', function()
    local remote = upstream()
    local dir = clone(remote, 'updirty.nvim')
    local before = head(dir)
    advance(remote)
    vim.fn.writefile({ 'my own edit' }, dir .. '/tracked.txt')
    updater.update(resolved({ { name = 'updirty.nvim', repo = remote } }))
    finish()
    h.eq(h.job('updirty.nvim', 'update').note, 'skipped: local changes')
    h.eq(head(dir), before)
    h.eq(vim.fn.readfile(dir .. '/tracked.txt'), { 'my own edit' })
    h.ok(h.notified('Left alone: updirty.nvim (skipped: local changes)'), vim.inspect(h.notes))
end)

test(
    "a remote that cannot be reached fails that plugin with git's message, and the others still update",
    function()
        local good, bad = upstream(), upstream()
        local good_dir, bad_dir = clone(good, 'upgood.nvim'), clone(bad, 'upbad.nvim')
        advance(good)
        git(bad_dir, 'remote', 'set-url', 'origin', 'file://' .. vim.fn.tempname() .. '/gone')
        updater.update(resolved({
            { name = 'upbad.nvim', repo = bad },
            { name = 'upgood.nvim', repo = good },
        }))
        finish()
        h.eq(h.job('upbad.nvim', 'update').status, 'failed')
        h.ok(#h.job('upbad.nvim', 'update').error > 0)
        h.eq(head(good_dir), head(good))
        h.ok(h.notified('Failed: upbad.nvim'), vim.inspect(h.notes))
    end
)

test('naming plugins updates only those', function()
    local one, two = upstream(), upstream()
    local one_dir, two_dir = clone(one, 'upone.nvim'), clone(two, 'uptwo.nvim')
    local untouched = head(two_dir)
    advance(one)
    advance(two)
    updater.update(
        resolved({ { name = 'upone.nvim', repo = one }, { name = 'uptwo.nvim', repo = two } }),
        { 'upone.nvim' }
    )
    finish()
    h.eq(head(one_dir), head(one))
    h.eq(head(two_dir), untouched)
    h.eq(stats.get().count, 2) -- the whole manifest stays registered
end)

test('a name that is not a plugin is an error, and nothing runs', function()
    local remote = upstream()
    clone(remote, 'upreal.nvim')
    updater.update(resolved({ { name = 'upreal.nvim', repo = remote } }), { 'upreal.nvim', 'upnone.nvim' })
    h.ok(h.notified('Unknown plugin: upnone.nvim'), vim.inspect(h.notes))
    h.eq(tasks.snapshot().total, 0)
end)

test('a plugin that is not installed is named, and not fetched', function()
    local remote = upstream()
    clone(remote, 'upthere.nvim')
    updater.check(
        resolved({ { name = 'upthere.nvim', repo = remote }, { name = 'upabsent.nvim', repo = remote } })
    )
    finish()
    h.ok(h.notified('Not installed, so not checked: upabsent.nvim'), vim.inspect(h.notes))
    h.eq(h.job('upabsent.nvim', 'check'), nil)
    h.eq(h.job('upthere.nvim', 'check').status, 'done')
end)

test('the summary says what moved, what was left alone and what failed, and at what level', function()
    local function job(mode, plugin, status, note, error)
        return { id = mode, plugin = plugin, status = status, note = note, error = error }
    end
    local text, level = updater.summarize('check', {
        job('check', 'a', 'done', 'update available abc1234 → def5678'),
        job('check', 'b', 'done', 'up to date'),
        job('build', 'a', 'done'),
    })
    h.eq({ text, level }, { '1 update available: a abc1234 → def5678 Run :Sarcina update.', 'info' })
    text, level = updater.summarize('update', {
        job('update', 'a', 'done', 'abc1234 → def5678'),
        job('update', 'b', 'done', 'skipped: local changes'),
        job('update', 'c', 'failed', nil, 'boom'),
    })
    h.eq(level, 'warn')
    h.ok(text:find('Updated 1 plugin: a abc1234 → def5678', 1, true), text)
    h.ok(text:find('Left alone: b (skipped: local changes).', 1, true), text)
    h.ok(text:find('Failed: c (boom).', 1, true), text)
    h.eq(
        { updater.summarize('update', { job('update', 'a', 'done', 'up to date') }) },
        { 'Everything is up to date.', 'info' }
    )
end)

test('a local plugin, one with a dir, is never fetched into, and is named when you ask for it', function()
    local remote = upstream()
    local dir = clone(remote, 'uplocal-src')
    local before = head(dir)
    advance(remote)
    updater.update(resolved({ { name = 'uplocal.nvim', repo = remote, dir = dir } }), { 'uplocal.nvim' })
    h.ok(h.notified('Local plugins are not updated: uplocal.nvim.'), vim.inspect(h.notes))
    h.eq(tasks.snapshot().total, 0)
    h.eq(head(dir), before)
end)

-- Puts a help file with the topics `topics` in the repo `dir`, and commits it.
local function add_help(dir, topics)
    vim.fn.mkdir(dir .. '/doc', 'p')
    local lines = { '*plug.txt*  A plugin', '' }
    for _, topic in ipairs(topics) do
        table.insert(lines, 'About *' .. topic .. '* here.')
    end
    vim.fn.writefile(lines, dir .. '/doc/plug.txt')
    git(dir, 'add', '-A')
    git(dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'docs')
end

local function tags_of(name) return table.concat(vim.fn.readfile(paths.install(name) .. '/doc/tags'), '\n') end

test('a clone makes its help findable at once, and an update makes the new topics findable', function()
    local remote = upstream()
    add_help(remote, { 'helpone-topic' })
    local install = { id = 'install', type = 'git_clone', repo = 'file://' .. remote, phase = 'install' }
    h.eq(h.run({ { name = 'helpclone.nvim', tasks = { install } } }).failed, 0)
    h.ok(tags_of('helpclone.nvim'):find('helpone-topic', 1, true), 'a clone has no tags')
    add_help(remote, { 'helpone-topic', 'helptwo-topic' })
    updater.update(resolved({ { name = 'helpclone.nvim', repo = 'file://' .. remote } }))
    finish()
    h.ok(tags_of('helpclone.nvim'):find('helptwo-topic', 1, true), 'an update left the tags as they were')
end)

test('an update leaves doc/tags alone when the plugin commits it', function()
    local remote = upstream()
    add_help(remote, { 'committed-topic' })
    vim.fn.writefile({ 'committed-topic\tplug.txt\t/*committed-topic*' }, remote .. '/doc/tags')
    git(remote, 'add', '-A')
    git(remote, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'tags')
    clone(remote, 'helpkept.nvim')
    advance(remote)
    updater.update(resolved({ { name = 'helpkept.nvim', repo = remote } }))
    finish()
    h.eq(head(paths.install('helpkept.nvim')), head(remote))
    h.eq(
        vim.fn.readfile(paths.install('helpkept.nvim') .. '/doc/tags'),
        { 'committed-topic\tplug.txt\t/*committed-topic*' }
    )
end)

-- Runs `fn` with the question on and `confirm.ask` answering `answer`; returns the prompts it was asked.
local function with_question(answer, fn)
    local confirm = require('sarcina.confirm')
    local ask, prompts = confirm.ask, {}
    confirm.enabled = true
    confirm.ask = function(prompt, callback)
        table.insert(prompts, prompt)
        callback(answer)
    end
    local ok, err = pcall(fn)
    confirm.ask, confirm.enabled = ask, false
    assert(ok, err)
    return prompts
end

test('update asks first, naming the newer commit, and moves the plugin on yes', function()
    local remote = upstream()
    local dir = clone(remote, 'upask.nvim')
    advance(remote)
    local prompts = with_question(true, function()
        updater.update(resolved({ { name = 'upask.nvim', repo = remote } }))
        finish()
        h.ok(vim.wait(5000, function() return head(dir) == head(remote) end, 20))
        finish()
    end)
    h.eq(#prompts, 1)
    h.ok(prompts[1]:find('Update 1 plugin?', 1, true) and prompts[1]:find('upask.nvim', 1, true), prompts[1])
end)

test('update leaves the plugin alone on no', function()
    local remote = upstream()
    local dir = clone(remote, 'upno.nvim')
    local before = head(dir)
    advance(remote)
    with_question(false, function()
        updater.update(resolved({ { name = 'upno.nvim', repo = remote } }))
        finish()
    end)
    h.eq(head(dir), before)
    h.ok(h.notified('Nothing updated'), vim.inspect(h.notes))
end)

test('update asks nothing when no plugin has a newer commit', function()
    local remote = upstream()
    clone(remote, 'upnone.nvim')
    local prompts = with_question(true, function()
        updater.update(resolved({ { name = 'upnone.nvim', repo = remote } }))
        finish()
    end)
    h.eq(#prompts, 0)
    h.ok(h.notified('Everything is up to date'), vim.inspect(h.notes))
end)

return tests
