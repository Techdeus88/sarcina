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

-- A plugin whose tasks come from the factory, with a shallow clone of `remote` as its install.
local function plugin(name, remote)
    return { name = name, tasks = factory.generate({ name = name, repo = url(remote) }) }
end

local function write_lock(entries)
    vim.fn.mkdir(vim.fs.dirname(paths.lock_file()), 'p')
    vim.fn.writefile({ vim.json.encode(entries) }, paths.lock_file())
    lock._reset()
end

test('a fresh clone is pinned to the commit the lock file names, and still tracks its remote', function()
    local remote = h.upstream()
    local pinned = h.head(remote)
    h.advance(remote)
    write_lock({ ['pinned.nvim'] = { commit = pinned } })
    h.eq(h.run({ plugin('pinned.nvim', remote) }).failed, 0)
    local dir = paths.install('pinned.nvim')
    h.eq(h.head(dir), pinned)
    h.ok(pinned ~= h.head(remote))
    -- The branch tracks upstream, so an update moves on from the pin.
    updater.update(resolver.resolve({ { name = 'pinned.nvim', repo = url(remote) } }))
    h.ok(tasks.wait(15000))
    h.eq(h.head(dir), h.head(remote))
end)

test('a locked commit that is already the latest costs nothing extra', function()
    local remote = h.upstream()
    write_lock({ ['latest.nvim'] = { commit = h.head(remote) } })
    h.eq(h.run({ plugin('latest.nvim', remote) }).failed, 0)
    h.eq(h.head(paths.install('latest.nvim')), h.head(remote))
end)

test('a locked commit that cannot be fetched fails the install and leaves nothing behind', function()
    local remote = h.upstream()
    write_lock({ ['lost.nvim'] = { commit = string.rep('d', 40) } })
    h.run({ plugin('lost.nvim', remote) })
    local install = h.job('lost.nvim', 'install')
    h.eq(install.status, 'failed')
    h.ok(install.error:find('locked commit ddddddd is not available: ', 1, true), install.error)
    h.eq(h.job('lost.nvim', 'rtp').status, 'skipped')
    h.eq(vim.uv.fs_stat(paths.install('lost.nvim')), nil)
    h.eq(vim.fn.glob(require('sarcina.paths').plugins_dir() .. '.staging/lost.nvim*', false, true), {})
end)

test('a plugin with no entry gets the latest commit, and the lock file names it after the run', function()
    local remote = h.upstream()
    h.eq(h.run({ plugin('free.nvim', remote) }).failed, 0)
    h.eq(h.head(paths.install('free.nvim')), h.head(remote))
    h.ok(
        vim.wait(3000, function()
            lock._reset()
            return lock.get('free.nvim') == h.head(remote)
        end, 20),
        'the lock file does not name the commit that was installed'
    )
end)

return tests
