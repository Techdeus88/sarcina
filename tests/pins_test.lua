local h = require('helpers')
local pins = require('sarcina.pin')
local resolver = require('sarcina.resolver')
local schema = require('sarcina.schema')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function of(spec)
    local pin = pins.of(spec)
    return pin and { pin.kind, pin.value }
end

test('commit, tag and branch are what they say', function()
    h.eq(of({ commit = 'b516f20b' }), { 'commit', 'b516f20b' })
    h.eq(of({ tag = 'v1.4.0' }), { 'tag', 'v1.4.0' })
    h.eq(of({ branch = 'master' }), { 'branch', 'master' })
    h.eq(of({}), nil)
    h.eq(of({ commit = '', tag = false }), nil)
end)

test('a version that is a range asks for the newest tag inside it', function()
    for _, range in ipairs({ '1.*', '^1.2', '~1.2.3', '>=1.0', '3', '*', 'v1.2.0' }) do
        h.eq(of({ version = range }), { 'version', range })
    end
    local pin = pins.of({ version = vim.version.range('1.*') })
    h.eq({ pin.kind, pin.value }, { 'version', '>=1.0.0 <2.0.0' })
    h.eq(pins.of({ version = vim.version.range('*') }).value, '>=0.0.0')
    h.eq(pins.of({ version = vim.version.range('1.2.3') }).value, '=1.2.3')
end)

test(
    'a version that is not a range is a commit when it looks like one, and a branch or tag name otherwise',
    function()
        h.eq(of({ version = 'b516f20b' }), { 'commit', 'b516f20b' })
        h.eq(of({ version = '9b5f7c1e0f6a2d4c8b1e3a7f5d2c9e4b6a8f0d13' })[1], 'commit')
        h.eq(of({ version = 'main' }), { 'ref', 'main' })
        h.eq(of({ version = 'stable' }), { 'ref', 'stable' })
        h.eq(of({ version = 'beef' }), { 'ref', 'beef' }) -- too short to be a commit
        h.eq(of({ version = false }), nil)
        h.eq(of({ version = '' }), nil)
    end
)

test('when a spec sets more than one, commit beats tag, tag beats version, version beats branch', function()
    local pin, ignored = pins.of({ branch = 'main', version = '1.*', tag = 'v1', commit = 'abcdef1' })
    h.eq({ pin.kind, ignored }, { 'commit', { 'tag', 'version', 'branch' } })
    pin, ignored = pins.of({ branch = 'main', version = '1.*' })
    h.eq({ pin.kind, ignored }, { 'version', { 'branch' } })
    h.eq(select(2, pins.of({ tag = 'v1' })), nil)
end)

test('a pin is described in words and keyed by its kind and value', function()
    local pin = pins.of({ tag = 'v1.4.0' })
    h.eq({ pins.describe(pin), pins.key(pin) }, { 'tag v1.4.0', 'tag:v1.4.0' })
    h.eq(pins.describe(pins.of({ version = 'main' })), 'ref main')
end)

test(
    'another spec of the same plugin gives its pin to one that has none, and a different one is refused',
    function()
        local into = { name = 'a' }
        h.eq(pins.adopt(into, { name = 'a', branch = 'master' }), true)
        h.eq(into.branch, 'master')
        h.eq(pins.adopt(into, { name = 'a' }), true)
        h.eq(pins.adopt(into, { name = 'a', branch = 'master' }), true)
        h.eq(pins.adopt(into, { name = 'a', tag = 'v1' }), false)
        h.eq(into.tag, nil)
    end
)

local LISTING = table.concat({
    string.rep('1', 40) .. '\trefs/tags/v0.9.0',
    string.rep('2', 40) .. '\trefs/tags/v1.0.0',
    string.rep('a', 40) .. '\trefs/tags/v1.2.0', -- an annotated tag: the object, then the commit it points at
    string.rep('b', 40) .. '\trefs/tags/v1.2.0^{}',
    string.rep('3', 40) .. '\trefs/tags/v1.3.0-rc1',
    string.rep('4', 40) .. '\trefs/tags/v2.0.0',
    string.rep('5', 40) .. '\trefs/tags/nightly',
    string.rep('6', 40) .. '\trefs/tags/1.1.0',
}, '\n')

test('refs reads what ls-remote printed, and a peeled tag gives the commit', function()
    local refs = pins.refs(LISTING)
    h.eq(refs['refs/tags/v1.2.0'], string.rep('b', 40))
    h.eq(refs['refs/tags/v1.0.0'], string.rep('2', 40))
    h.eq(refs['refs/tags/v1.2.0^{}'], nil)
    -- The peeled line may come first.
    h.eq(
        pins.refs(string.rep('b', 40) .. '\trefs/tags/x^{}\n' .. string.rep('a', 40) .. '\trefs/tags/x')['refs/tags/x'],
        string.rep('b', 40)
    )
end)

test(
    'newest takes the highest tag inside the range, skipping prereleases and names that are not versions',
    function()
        local refs = pins.refs(LISTING)
        local function newest(version) return { pins.newest(pins.of({ version = version }), refs) } end
        h.eq(newest('1.*'), { 'v1.2.0', string.rep('b', 40) })
        h.eq(newest('^0.9'), { 'v0.9.0', string.rep('1', 40) })
        h.eq(newest('*'), { 'v2.0.0', string.rep('4', 40) })
        h.eq(newest('1.1'), { '1.1.0', string.rep('6', 40) }) -- a tag with no v counts
        h.eq(newest('3'), {})
        h.eq(
            { pins.newest(pins.of({ version = vim.version.range('~1.1') }), refs) },
            { '1.1.0', string.rep('6', 40) }
        )
    end
)

test('two tags of one version choose the same one every time', function()
    local refs =
        pins.refs(string.rep('1', 40) .. '\trefs/tags/v1.0.0\n' .. string.rep('2', 40) .. '\trefs/tags/1.0.0')
    for _ = 1, 5 do
        h.eq((pins.newest(pins.of({ version = '1.*' }), refs)), '1.0.0')
    end
end)

test('the resolver warns about the keys a stronger one outranks, and keeps going', function()
    local resolved = resolver.resolve({ { repo = 'owner/both.nvim', tag = 'v1.0.0', branch = 'main' } })
    h.eq(#resolved, 1)
    h.ok(h.notified('both.nvim: ignoring branch, which tag v1.0.0 outranks'), vim.inspect(h.notes))
end)

test('a second spec of a plugin brings its pin, as an inline dependency does', function()
    local resolved = resolver.resolve({
        { repo = 'owner/user.nvim', deps = { 'owner/plenary.nvim' } },
        { repo = 'owner/other.nvim', deps = { { 'owner/plenary.nvim', branch = 'master' } } },
    })
    local by_name = {}
    for _, entry in ipairs(resolved) do
        by_name[entry.name] = entry.spec
    end
    h.eq(by_name['plenary.nvim'].branch, 'master')
    h.eq(by_name['plenary.nvim'].tasks[1].pin.value, 'master')
    h.eq(#h.notes, 0, vim.inspect(h.notes))
end)

test('a second spec that pins a plugin differently is named, and the first pin is kept', function()
    local resolved = resolver.resolve({
        { repo = 'owner/user.nvim', deps = { { 'owner/lib.nvim', tag = 'v1' } } },
        { repo = 'owner/other.nvim', deps = { { 'owner/lib.nvim', tag = 'v2' } } },
    })
    for _, entry in ipairs(resolved) do
        if entry.name == 'lib.nvim' then h.eq(entry.spec.tag, 'v1') end
    end
    h.ok(h.notified('lib.nvim is pinned differently by two specs, so tag v1 is kept'), vim.inspect(h.notes))
end)

test('the schema checks the types of the pin keys', function()
    h.eq(
        schema.validate_manifest({
            { repo = 'a/b', tag = 'v1', branch = 'x', commit = 'abc1234', version = '1.*' },
        }),
        true
    )
    h.eq(schema.validate_manifest({ { repo = 'a/b', version = vim.version.range('1.*') } }), true)
    h.eq(schema.validate_manifest({ { repo = 'a/b', version = false } }), true)
    h.eq(schema.validate_manifest({ { repo = 'a/b', tag = 1 } }), false)
    h.ok(h.notified('field `tag` must be string, got number'), vim.inspect(h.notes))
    h.eq(schema.validate_manifest({ { repo = 'a/b', branch = true } }), false)
    h.eq(schema.validate_manifest({ { repo = 'a/b', commit = {} } }), false)
end)

return tests
