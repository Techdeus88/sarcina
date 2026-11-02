local h = require('helpers')
local lock = require('sarcina.lock')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function read_file() return vim.json.decode(table.concat(vim.fn.readfile(paths.lock_file()), '\n')) end

local function names()
    local keys = vim.tbl_keys(read_file())
    table.sort(keys)
    return keys
end

local function head(dir) return vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', 'HEAD' })) end

-- Each test starts without a file, as a first launch does.
local function fresh()
    vim.fn.delete(paths.lock_file(), 'rf')
    lock._reset()
end

-- Flushes and waits for the file.
local function flush()
    local written
    lock.flush(function(ok) written = ok end)
    h.ok(vim.wait(2000, function() return written ~= nil end, 5), 'the lock file was never written')
    return written
end

if vim.fn.executable('git') == 0 then return {} end

test(
    'the lock file is in the config directory, next to your specs',
    function() h.eq(paths.lock_file(), vim.fn.stdpath('config') .. '/sarcina-lock.json') end
)

test('a plugin with no entry has no locked commit, and asking makes no file', function()
    fresh()
    h.eq(lock.get('lkone.nvim'), nil)
    h.eq(vim.uv.fs_stat(paths.lock_file()), nil)
end)

test('flush writes the HEAD of each marked plugin, as sorted JSON, and get reads it back', function()
    fresh()
    local one, two = h.make_repo(), h.make_repo()
    lock.mark('lkb.nvim', two)
    lock.mark('lka.nvim', one)
    h.eq(flush(), true)
    local saved = read_file()
    h.eq({ saved['lka.nvim'].commit, saved['lkb.nvim'].commit }, { head(one), head(two) })
    local text = table.concat(vim.fn.readfile(paths.lock_file()), '\n')
    h.ok(text:find('lka.nvim', 1, true) < text:find('lkb.nvim', 1, true), 'the file is not sorted')
    lock._reset() -- a new session reads the file
    h.eq(lock.get('lka.nvim'), head(one))
end)

test('flush keeps the entries of plugins it was not asked about', function()
    fresh()
    local one = h.make_repo()
    lock.mark('lkkeep.nvim', one)
    flush()
    lock.mark('lknew.nvim', h.make_repo())
    flush()
    h.eq(names(), { 'lkkeep.nvim', 'lknew.nvim' })
end)

test('flush with nothing marked writes nothing, and a directory that is no repo gets no entry', function()
    fresh()
    local called = false
    lock.flush(function() called = true end)
    h.eq(called, true)
    h.eq(vim.uv.fs_stat(paths.lock_file()), nil)
    local plain = vim.fn.tempname()
    vim.fn.mkdir(plain, 'p')
    lock.mark('lkplain.nvim', plain)
    lock.mark('lkreal.nvim', h.make_repo())
    flush()
    h.eq(names(), { 'lkreal.nvim' })
end)

test('a file that cannot be read counts as empty and is replaced by the next write', function()
    fresh()
    vim.fn.mkdir(vim.fs.dirname(paths.lock_file()), 'p')
    vim.fn.writefile({ '{ not json' }, paths.lock_file())
    h.eq(lock.get('lkbad.nvim'), nil)
    local repo = h.make_repo()
    lock.mark('lkbad.nvim', repo)
    flush()
    h.eq(read_file()['lkbad.nvim'].commit, head(repo))
    h.eq(vim.fn.glob(paths.lock_file() .. '.tmp'), '')
    h.eq(vim.fn.readfile(paths.lock_file() .. '.bak'), { '{ not json' })
    vim.fn.delete(paths.lock_file() .. '.bak')
end)

test('forget drops the entries of removed plugins and keeps the rest', function()
    fresh()
    lock.mark('lkgone.nvim', h.make_repo())
    lock.mark('lkstay.nvim', h.make_repo())
    flush()
    lock.forget({ 'lkgone.nvim', 'lknever.nvim' })
    h.eq(names(), { 'lkstay.nvim' })
end)

test('a lock file that cannot be written warns once', function()
    fresh()
    vim.fn.mkdir(paths.lock_file(), 'p') -- a directory where the file belongs: the rename fails
    lock.mark('lkfail.nvim', h.make_repo())
    h.eq(flush(), false)
    lock.mark('lkfail2.nvim', h.make_repo())
    flush()
    local warnings = 0
    for _, note in ipairs(h.notes) do
        if note.msg:find('Could not write the lock file', 1, true) then warnings = warnings + 1 end
    end
    vim.fn.delete(paths.lock_file(), 'rf')
    h.eq(warnings, 1)
end)

return tests
