local h = require('helpers')
local factory = require('sarcina.task_factory')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function find(tasks, id)
    for _, task in ipairs(tasks) do
        if task.id == id then return task end
    end
end

test(
    'a bare repo gets install and rtp only',
    function() h.eq(h.ids(factory.generate({ repo = 'x/y' })), { 'install', 'rtp' }) end
)

test('an eager plugin orders every phase', function()
    local tasks = factory.generate({
        repo = 'x/y',
        init = 'a',
        build = 'b',
        config = 'c',
        after = 'd',
    })
    h.eq(h.ids(tasks), { 'before', 'install', 'build', 'rtp', 'load', 'after' })
end)

test('a lazy plugin defers rtp, load and after into the trigger task', function()
    local tasks = factory.generate({
        repo = 'x/y',
        init = 'a',
        build = 'b',
        event = 'BufRead',
        config = 'c',
        after = 'd',
    })
    h.eq(h.ids(tasks), { 'before', 'install', 'build', 'load_trigger' })
    local trigger = find(tasks, 'load_trigger')
    h.eq(h.ids(trigger.deferred), { 'rtp', 'load', 'after' })
    h.eq(trigger.triggers, { event = { 'BufRead' } })
end)

test('triggers are normalized to lists', function()
    local triggers = factory.triggers({ event = 'BufRead', cmd = 'Foo', keys = { '<F5>', { '<F6>', 'n' } } })
    h.eq(triggers, { event = { 'BufRead' }, cmd = { 'Foo' }, keys = { '<F5>', { '<F6>', 'n' } } })
    h.eq(factory.triggers({ repo = 'x/y' }), nil)
end)

test(
    'triggers = false keeps a plugin eager',
    function()
        h.eq(
            h.ids(factory.generate({ repo = 'x/y', event = 'BufRead', triggers = false })),
            { 'install', 'rtp' }
        )
    end
)

test('keeps function values as closures', function()
    local called = false
    local tasks = factory.generate({
        repo = 'x/y',
        build = function() called = true end,
    })
    find(tasks, 'build').fn()
    h.ok(called)
end)

test(
    'keeps string values as scripts',
    function() h.eq(find(factory.generate({ repo = 'x/y', build = 'return 1' }), 'build').script, 'return 1') end
)

test('a string starting with a colon becomes an Ex command task', function()
    local tasks =
        factory.generate({ repo = 'x/y', build = ':RealIcons install', after = ':doautocmd User Done' })
    h.eq(find(tasks, 'build'), { id = 'build', type = 'cmd', cmd = 'RealIcons install', per_commit = true })
    h.eq(find(tasks, 'after').cmd, 'doautocmd User Done')
end)

test('only the build task is gated by the commit', function()
    local tasks = factory.generate({ repo = 'x/y', init = h.noop, build = h.noop, after = h.noop })
    h.eq(find(tasks, 'build').per_commit, true)
    h.eq(find(tasks, 'before').per_commit, nil)
    h.eq(find(tasks, 'after').per_commit, nil)
end)

test('hands opts to config as the second argument', function()
    local got
    local tasks = factory.generate({
        repo = 'x/y',
        opts = { a = 1 },
        config = function(_, opts) got = opts end,
    })
    local load = find(tasks, 'load')
    load.fn(nil, load.opts)
    h.eq(got, { a = 1 })
end)

test('main with opts calls setup(opts)', function()
    local got
    package.preload['sarcina_test_mod'] = function()
        return {
            setup = function(opts) got = opts end,
        }
    end
    local load = find(factory.generate({ repo = 'x/y', main = 'sarcina_test_mod', opts = { b = 2 } }), 'load')
    load.fn(nil, load.opts)
    package.preload['sarcina_test_mod'], package.loaded['sarcina_test_mod'] = nil, nil
    h.eq(got, { b = 2 })
end)

test('main without opts only requires the module', function()
    local required, setup_called = false, false
    package.preload['sarcina_test_mod2'] = function()
        required = true
        return {
            setup = function() setup_called = true end,
        }
    end
    local load = find(factory.generate({ repo = 'x/y', main = 'sarcina_test_mod2' }), 'load')
    load.fn(nil, load.opts)
    package.preload['sarcina_test_mod2'], package.loaded['sarcina_test_mod2'] = nil, nil
    h.eq({ required, setup_called }, { true, false })
end)

test('opts alone find the main module and call setup(opts)', function()
    local dir = h.plugin_dir({ derivedmod = 'return { setup = function(o) _G.derived_opts = o end }' })
    vim.opt.rtp:append(dir)
    local spec = { name = 'derivedmod.nvim', repo = 'x/derivedmod.nvim', opts = { c = 3 } }
    local load = find(factory.generate(spec), 'load')
    load.fn({ name = 'derivedmod.nvim', dir = dir }, load.opts)
    vim.opt.rtp:remove(dir)
    package.loaded.derivedmod = nil
    h.eq(_G.derived_opts, { c = 3 })
    _G.derived_opts = nil
end)

test('opts alone fall back to the repo name when the plugin name differs', function()
    local dir = h.plugin_dir({
        reponamed = 'return { setup = function(o) _G.repo_opts = o end }',
        other = 'return {}',
    })
    vim.opt.rtp:append(dir)
    local load =
        find(factory.generate({ name = 'colors', repo = 'x/reponamed.nvim', opts = { d = 4 } }), 'load')
    load.fn({ name = 'colors', dir = dir }, load.opts)
    vim.opt.rtp:remove(dir)
    package.loaded.reponamed = nil
    h.eq(_G.repo_opts, { d = 4 })
    _G.repo_opts = nil
end)

test('opts alone fail with advice when the main module is ambiguous', function()
    local dir = h.plugin_dir({ alpha = 'return {}', beta = 'return {}' })
    local load = find(factory.generate({ name = 'gamma.nvim', repo = 'x/gamma.nvim', opts = {} }), 'load')
    local ok, err = pcall(load.fn, { name = 'gamma.nvim', dir = dir }, load.opts)
    h.eq(ok, false)
    h.ok(err:find('set `main`', 1, true), err)
end)

test('opts fail when the main module has no setup', function()
    local dir = h.plugin_dir({ nosetup = 'return {}' })
    vim.opt.rtp:append(dir)
    local load = find(factory.generate({ name = 'nosetup.nvim', repo = 'x/nosetup.nvim', opts = {} }), 'load')
    local ok, err = pcall(load.fn, { name = 'nosetup.nvim', dir = dir }, load.opts)
    vim.opt.rtp:remove(dir)
    package.loaded.nosetup = nil
    h.eq(ok, false)
    h.ok(err:find('has no setup()', 1, true), err)
end)

return tests
