local h = require('helpers')
local factory = require('sarcina.task_factory')
local lock = require('sarcina.lock')
local paths = require('sarcina.paths')
local resolver = require('sarcina.resolver')
local tasks = require('sarcina.tasks')
local updater = require('sarcina.updater')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

if vim.fn.executable('git') == 0 then return {} end

local function url(remote) return 'file://' .. remote end

local function spec_of(name, remote, pin)
    return vim.tbl_extend('force', { name = name, repo = url(remote) }, pin or {})
end

-- Installs `name` from `remote` with the pin keys of `pin`, through the factory's tasks. Returns its directory.
local function install(name, remote, pin)
    h.run({ { name = name, tasks = factory.generate(spec_of(name, remote, pin)) } })
    return paths.install(name)
end

local function update(name, remote, pin, mode)
    updater[mode or 'update'](resolver.resolve({ spec_of(name, remote, pin) }))
    h.ok(tasks.wait(15000), 'the run did not finish')
    return h.job(name, mode or 'update')
end

local function tag(dir, name, annotated)
    if annotated then
        h.git(dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'tag', '-a', name, '-m', name)
    else
        h.git(dir, 'tag', name)
    end
end

local function branch(dir) return h.git(dir, 'rev-parse', '--abbrev-ref', 'HEAD') end

-- Waits for the lock file entry of `name` to be `entry`.
local function locked(name, entry)
    local data
    local found = vim.wait(3000, function()
        data = vim.json.decode(table.concat(vim.fn.readfile(paths.lock_file()), '\n'))[name]
        return vim.deep_equal(data, entry)
    end, 20)
    return found, vim.inspect(data)
end

local function write_lock(entries)
    vim.fn.mkdir(vim.fs.dirname(paths.lock_file()), 'p')
    vim.fn.writefile({ vim.json.encode(entries) }, paths.lock_file())
    lock._reset()
end

test('a branch pin clones that branch, and update follows it', function()
    local remote = h.upstream()
    local default = branch(remote)
    h.git(remote, 'checkout', '-q', '-b', 'dev')
    h.advance(remote)
    local dev = h.head(remote)
    h.git(remote, 'checkout', '-q', default)
    h.advance(remote)
    local dir = install('branchy.nvim', remote, { branch = 'dev' })
    h.eq(h.job('branchy.nvim', 'install').status, 'done')
    h.eq(h.head(dir), dev)
    h.git(remote, 'checkout', '-q', 'dev')
    h.advance(remote)
    h.ok(update('branchy.nvim', remote, { branch = 'dev' }, 'check').note:find('^update available'))
    h.eq(h.head(dir), dev)
    update('branchy.nvim', remote, { branch = 'dev' })
    h.eq(h.head(dir), h.head(remote))
    h.ok(locked('branchy.nvim', { commit = h.head(remote), pin = 'branch:dev' }))
end)

test('a tag pin checks out the commit of the tag, annotated or not, and update leaves it there', function()
    local remote = h.upstream()
    local first = h.head(remote)
    tag(remote, 'v1.0.0', true)
    h.advance(remote)
    local second = h.head(remote)
    tag(remote, 'v1.1.0')
    h.advance(remote)
    h.eq(h.head(install('annotated.nvim', remote, { tag = 'v1.0.0' })), first)
    h.eq(h.head(install('light.nvim', remote, { tag = 'v1.1.0' })), second)
    h.ok(locked('annotated.nvim', { commit = first, pin = 'tag:v1.0.0' }))
    h.eq(update('annotated.nvim', remote, { tag = 'v1.0.0' }).note, 'up to date')
    h.eq(h.head(paths.install('annotated.nvim')), first)
end)

test('a version range checks out the newest tag inside it, and update moves to a newer one', function()
    local remote = h.upstream()
    local commits = {}
    for _, name in ipairs({ 'v0.9.0', 'v1.0.0', 'v1.2.0', 'v1.3.0-rc1', 'v2.0.0', 'nightly' }) do
        tag(remote, name, name == 'v1.2.0')
        commits[name] = h.head(remote)
        h.advance(remote)
    end
    h.eq(h.head(install('ranged.nvim', remote, { version = '1.*' })), commits['v1.2.0'])
    h.eq(h.head(install('object.nvim', remote, { version = vim.version.range('^1.0') })), commits['v1.2.0'])
    h.eq(h.head(install('star.nvim', remote, { version = '*' })), commits['v2.0.0'])
    h.ok(locked('ranged.nvim', { commit = commits['v1.2.0'], pin = 'version:1.*' }))
    h.eq(update('ranged.nvim', remote, { version = '1.*' }, 'check').note, 'up to date')
    tag(remote, 'v1.2.5')
    local newer = h.head(remote)
    local job = update('ranged.nvim', remote, { version = '1.*' })
    h.eq(job.note, commits['v1.2.0']:sub(1, 7) .. ' → ' .. newer:sub(1, 7))
    h.eq(h.head(paths.install('ranged.nvim')), newer)
end)

test('a commit pin checks out that commit, in full or abbreviated, and update keeps it there', function()
    local remote = h.upstream()
    local old = h.head(remote)
    h.advance(remote)
    h.advance(remote)
    h.eq(h.head(install('full.nvim', remote, { commit = old })), old)
    local short = old:sub(1, 8)
    local dir = install('short.nvim', remote, { commit = short })
    h.eq(h.job('short.nvim', 'install').status, 'done', h.job('short.nvim', 'install').error)
    h.eq(h.head(dir), old)
    -- The lock file names the commit in full, so another machine fetches it without the history.
    h.ok(locked('short.nvim', { commit = old, pin = 'commit:' .. short }))
    h.eq(update('short.nvim', remote, { commit = short }, 'check').note, 'up to date')
    h.eq(update('short.nvim', remote, { commit = short }).note, 'up to date')
    h.eq(h.head(dir), old)
end)

test('a version that is not a range names a branch, a tag or a commit', function()
    local remote = h.upstream()
    local old = h.head(remote)
    tag(remote, 'stable')
    h.advance(remote)
    h.git(remote, 'checkout', '-q', '-b', 'edge')
    h.advance(remote)
    local edge = h.head(remote)
    h.eq(h.head(install('bytag.nvim', remote, { version = 'stable' })), old)
    h.eq(h.head(install('bybranch.nvim', remote, { version = 'edge' })), edge)
    -- A string of digits is read as a version, so the abbreviation has to hold a letter, as a real one mostly does.
    local abbreviated = old:sub(1, 10)
    for length = 11, 40 do
        if abbreviated:find('%a') then break end
        abbreviated = old:sub(1, length)
    end
    h.eq(h.head(install('bycommit.nvim', remote, { version = abbreviated })), old)
    h.advance(remote)
    update('bybranch.nvim', remote, { version = 'edge' })
    h.eq(h.head(paths.install('bybranch.nvim')), h.head(remote))
end)

test('a pin the remote does not have fails the install, says why, and leaves nothing behind', function()
    local remote = h.upstream()
    tag(remote, 'v1.0.0')
    local errors = {}
    for name, pin in pairs({
        ['nobranch.nvim'] = { branch = 'nope' },
        ['notag.nvim'] = { tag = 'v9.9.9' },
        ['norange.nvim'] = { version = '5.*' },
        ['nocommit.nvim'] = { commit = string.rep('d', 40) },
    }) do
        install(name, remote, pin)
        local job = h.job(name, 'install')
        h.eq(job.status, 'failed', name)
        h.eq(vim.uv.fs_stat(paths.install(name)), nil)
        h.eq(vim.fn.glob(paths.plugins_dir() .. '.staging/' .. name .. '*', false, true), {})
        errors[name] = job.error
    end
    h.ok(errors['nobranch.nvim']:find('nope'), errors['nobranch.nvim'])
    h.ok(errors['notag.nvim']:find('v9.9.9', 1, true), errors['notag.nvim'])
    h.eq(errors['norange.nvim'], 'no tag matches version 5.*')
    h.ok(errors['nocommit.nvim']:find('^commit ddddddd is not available: '), errors['nocommit.nvim'])
end)

test('update moves a plugin to its new pin, back in history too, and the lock file follows', function()
    local remote = h.upstream()
    local first = h.head(remote)
    tag(remote, 'v1.0.0')
    h.advance(remote)
    local second = h.head(remote)
    tag(remote, 'v2.0.0')
    h.advance(remote)
    local dir = install('moving.nvim', remote, { tag = 'v1.0.0' })
    h.eq(h.head(dir), first)
    update('moving.nvim', remote, { tag = 'v2.0.0' })
    h.eq(h.head(dir), second)
    h.ok(locked('moving.nvim', { commit = second, pin = 'tag:v2.0.0' }))
    update('moving.nvim', remote, { commit = first })
    h.eq(h.head(dir), first)
    -- Without a pin it goes to the default branch.
    update('moving.nvim', remote)
    h.eq(h.head(dir), h.head(remote))
    h.ok(locked('moving.nvim', { commit = h.head(remote) }))
end)

test('a pin the remote lost fails the update and leaves the plugin where it is', function()
    local remote = h.upstream()
    local dir = install('lost.nvim', remote)
    local before = h.head(dir)
    local job = update('lost.nvim', remote, { branch = 'gone' })
    h.eq({ job.status, job.error }, { 'failed', 'branch gone not found on the remote' })
    h.eq(h.head(dir), before)
end)

test('the lock file pins a clone only while the spec asks for the pin its commit came from', function()
    local remote = h.upstream()
    local first = h.head(remote)
    tag(remote, 'v1.0.0')
    h.advance(remote)
    local second = h.head(remote)
    h.advance(remote)
    -- Locked without a pin, so the tag the spec asks for now wins.
    write_lock({ ['retag.nvim'] = { commit = second } })
    h.eq(h.head(install('retag.nvim', remote, { tag = 'v1.0.0' })), first)
    -- Locked for this pin: the lock wins over where the branch is now.
    write_lock({ ['kept.nvim'] = { commit = second, pin = 'branch:' .. branch(remote) } })
    h.eq(h.head(install('kept.nvim', remote, { branch = branch(remote) })), second)
    -- Locked for a pin the spec no longer has: the latest.
    write_lock({ ['unpinned.nvim'] = { commit = first, pin = 'tag:v1.0.0' } })
    h.eq(h.head(install('unpinned.nvim', remote)), h.head(remote))
end)

return tests
