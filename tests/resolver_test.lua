local h = require('helpers')
local resolver = require('sarcina.resolver')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

test('derives the plugin name from a bare repo', function()
    local resolved = resolver.resolve({ { repo = 'nvim-lua/plenary.nvim' } })
    h.eq(h.names(resolved), { 'plenary.nvim' })
end)

test('puts dependencies before the plugins that need them', function()
    local resolved = resolver.resolve({
        { name = 'app', repo = 'x/app', deps = { 'lib' } },
        { name = 'lib', repo = 'x/lib', deps = { 'base' } },
        { name = 'base', repo = 'x/base' },
    })
    h.eq(h.names(resolved), { 'base', 'lib', 'app' })
end)

test('keeps manifest order for independent plugins', function()
    local specs = {}
    for _, name in ipairs({ 'e', 'b', 'd', 'a', 'c' }) do
        table.insert(specs, { name = name, repo = 'x/' .. name })
    end
    h.eq(h.names(resolver.resolve(specs)), { 'e', 'b', 'd', 'a', 'c' })
end)

test('rejects a dependency cycle', function()
    local resolved = resolver.resolve({
        { name = 'a', repo = 'x/a', deps = { 'b' } },
        { name = 'b', repo = 'x/b', deps = { 'a' } },
    })
    h.eq(resolved, {})
    h.ok(h.notified('Circular dependency'))
end)

test('rejects an unknown dependency', function()
    local resolved = resolver.resolve({ { name = 'a', repo = 'x/a', deps = { 'ghost' } } })
    h.eq(resolved, {})
    h.ok(h.notified('unknown dependency ghost'))
end)

test('sets spec.triggers from event, ft, cmd and keys', function()
    local resolved = resolver.resolve({ { name = 'a', repo = 'x/a', event = 'BufRead', cmd = 'Foo' } })
    h.eq(resolved[1].spec.triggers, { event = { 'BufRead' }, cmd = { 'Foo' } })
    h.eq(h.ids(resolved[1].spec.tasks), { 'install', 'load_trigger' })
end)

test('leaves spec.triggers nil for a plugin that loads eagerly', function()
    local resolved = resolver.resolve({ { name = 'a', repo = 'x/a' } })
    h.eq(resolved[1].spec.triggers, nil)
end)

test('an eager plugin forces its lazy dependencies to load eagerly, transitively', function()
    local resolved = resolver.resolve({
        { name = 'app', repo = 'x/app', deps = { 'lib' } },
        { name = 'lib', repo = 'x/lib', event = 'BufRead', deps = { 'base' } },
        { name = 'base', repo = 'x/base', cmd = 'Base' },
        { name = 'other', repo = 'x/other', cmd = 'Other' },
    })
    local spec = {}
    for _, entry in ipairs(resolved) do
        spec[entry.name] = entry.spec
    end
    h.eq(spec.lib.triggers, false)
    h.eq(spec.base.triggers, false)
    h.eq(h.ids(spec.base.tasks), { 'install', 'rtp' })
    h.eq(type(spec.other.triggers), 'table')
end)

test('a lazy plugin keeps its lazy dependencies lazy', function()
    local resolved = resolver.resolve({
        { name = 'a', repo = 'x/a', cmd = 'A', deps = { 'b' } },
        { name = 'b', repo = 'x/b', event = 'BufRead' },
    })
    for _, entry in ipairs(resolved) do
        h.eq(type(entry.spec.triggers), 'table', entry.name)
    end
end)

test('resolving is silent when nothing is wrong', function()
    resolver.resolve({ { repo = 'nvim-lua/plenary.nvim' }, { name = 'b', repo = 'x/b' } })
    h.eq(h.notes, {})
end)

test('attaches generated tasks to each spec', function()
    local resolved = resolver.resolve({ { name = 'a', repo = 'x/a' } })
    h.eq(h.ids(resolved[1].spec.tasks), { 'install', 'rtp' })
end)

return tests
