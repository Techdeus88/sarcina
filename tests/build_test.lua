local h = require('helpers')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function plugin_dir(name)
    local dir = paths.install(name)
    vim.fn.mkdir(dir, 'p')
    return dir
end

if vim.fn.executable('sh') == 1 then
    test('a shell task runs in the plugin directory', function()
        local dir = plugin_dir('shelled.nvim')
        local build = { id = 'build', type = 'shell', cmd = 'echo built > out.txt' }
        h.eq(h.run({ { name = 'shelled.nvim', tasks = { build } } }).failed, 0)
        h.eq(vim.fn.readfile(dir .. '/out.txt'), { 'built' })
    end)

    test('a failing shell task reports its last output line', function()
        plugin_dir('shellfail.nvim')
        local build = { id = 'build', type = 'shell', cmd = 'echo no luck >&2; exit 3' }
        h.run({ { name = 'shellfail.nvim', tasks = { build } } })
        local job = h.job('shellfail.nvim', 'build')
        h.eq(job.status, 'failed')
        h.eq(job.error, 'no luck')
    end)
end

test('a function build can call into the plugin because it is on the runtimepath', function()
    local dir = plugin_dir('autoload.nvim')
    vim.fn.mkdir(dir .. '/autoload', 'p')
    vim.fn.writefile(
        { 'function! sarcinabuild#run() abort', '  let g:autoload_built = 1', 'endfunction' },
        dir .. '/autoload/sarcinabuild.vim'
    )
    local build = h.lua('build', function() vim.fn['sarcinabuild#run']() end, { per_commit = true })
    h.eq(h.run({ { name = 'autoload.nvim', tasks = { build } } }).failed, 0)
    vim.opt.rtp:remove(dir)
    h.eq(vim.g.autoload_built, 1)
end)

local function load_with(opts)
    local got
    local load = h.lua('load', function(_, resolved) got = resolved end, { opts = opts })
    h.run({ { name = 'optsfn', tasks = { load } } })
    return got
end

test('opts given as a function can return the table', function()
    h.eq(load_with(function() return { a = 1 } end), { a = 1 })
end)

test('opts given as a function can fill in the table it receives', function()
    h.eq(load_with(function(plugin, opts) opts.name = plugin.name end), { name = 'optsfn' })
end)

test('opts given as a function that does neither gives setup an empty table', function()
    h.eq(load_with(function() end), {})
end)

test(
    'opts given as a table are passed through as they are',
    function() h.eq(load_with({ b = 2 }), { b = 2 }) end
)

return tests
