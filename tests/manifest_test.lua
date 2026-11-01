local h = require('helpers')
local manifest = require('sarcina.manifest')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local function spec_dir()
    local dir = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(dir, 'p')
    return dir
end

test('a spec file loads once when its directory is also passed in spec_paths', function()
    local dir = spec_dir()
    local file = dir .. '/manifest_once.lua'
    vim.fn.writefile({ "return { { 'x/once.nvim' } }" }, file)
    local specs = manifest.load({ spec_paths = { dir, dir .. '/' } })
    vim.fn.delete(file)
    h.eq(vim.tbl_map(function(spec) return spec.repo end, specs), { 'x/once.nvim' })
end)

test('a spec directory nested inside another loads its files once', function()
    local dir = spec_dir()
    vim.fn.mkdir(dir .. '/sub', 'p')
    local file = dir .. '/sub/manifest_nested.lua'
    vim.fn.writefile({ "return { { 'x/nested.nvim' } }" }, file)
    local specs = manifest.load({ spec_paths = { dir .. '/sub' } })
    vim.fn.delete(dir .. '/sub', 'rf')
    h.eq(#specs, 1)
    h.eq(specs[1].repo, 'x/nested.nvim')
end)

test('expand_shorthand moves the first entry to repo', function()
    local spec = { 'owner/repo', opts = {} }
    manifest.expand_shorthand(spec)
    h.eq(spec, { repo = 'owner/repo', opts = {} })
    local named = { 'ignored', repo = 'keep/me' }
    manifest.expand_shorthand(named)
    h.eq(named.repo, 'keep/me')
end)

return tests
