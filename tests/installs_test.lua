local h = require('helpers')
local installs = require('sarcina.installs')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function read_file() return vim.json.decode(table.concat(vim.fn.readfile(paths.installs_file()), '\n')) end

-- Each test starts without a file, as a first launch does.
local function fresh()
    vim.fn.delete(paths.installs_file())
    installs._reset()
end

test('a plugin with no record has none, and no file is made by asking', function()
    fresh()
    h.eq(installs.get('inone.nvim'), nil)
    h.eq(vim.uv.fs_stat(paths.installs_file()), nil)
end)

test('a record is written to a JSON file next to the plugins and read back by a later session', function()
    fresh()
    local before = os.time()
    installs.record('irec.nvim', 1234.5)
    h.eq(vim.fs.dirname(paths.installs_file()), vim.fn.stdpath('data') .. '/sarcina')
    local saved = read_file()['irec.nvim']
    h.eq(saved.ms, 1234.5)
    h.ok(saved.at >= before and saved.at <= os.time(), 'the time of the install is off: ' .. saved.at)
    installs._reset() -- a new session reads the file
    h.eq(installs.get('irec.nvim').ms, 1234.5)
end)

test('the time is kept to a tenth of a millisecond', function()
    fresh()
    installs.record('iround.nvim', 85.25024999999999)
    h.eq(read_file()['iround.nvim'].ms, 85.3)
end)

test('records of several plugins are kept, and a plugin installed again replaces its own', function()
    fresh()
    installs.record('ione.nvim', 100)
    installs.record('itwo.nvim', 200)
    installs.record('ione.nvim', 300)
    local saved = read_file()
    h.eq({ saved['ione.nvim'].ms, saved['itwo.nvim'].ms }, { 300, 200 })
end)

test('the records of another Neovim survive a write', function()
    fresh()
    installs.record('imine.nvim', 1)
    local saved = read_file()
    saved['itheirs.nvim'] = { ms = 2, at = 1 }
    vim.fn.writefile({ vim.json.encode(saved) }, paths.installs_file())
    installs.record('imine2.nvim', 3)
    local names = vim.tbl_keys(read_file())
    table.sort(names)
    h.eq(names, { 'imine.nvim', 'imine2.nvim', 'itheirs.nvim' })
end)

test('a file that cannot be read counts as no records and is replaced by the next write', function()
    fresh()
    vim.fn.mkdir(vim.fs.dirname(paths.installs_file()), 'p')
    vim.fn.writefile({ '{ this is not json' }, paths.installs_file())
    h.eq(installs.get('ibad.nvim'), nil)
    installs.record('ibad.nvim', 5)
    h.eq(read_file()['ibad.nvim'].ms, 5)
    h.eq(vim.fn.glob(paths.installs_file() .. '.tmp'), '')
end)

return tests
