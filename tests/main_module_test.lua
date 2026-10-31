local h = require('helpers')
local main_module = require('sarcina.main_module')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

test('matches a plugin name to a module, ignoring nvim affixes and punctuation', function()
    local cases = {
        { 'telescope.nvim', 'telescope' },
        { 'nvim-treesitter', 'treesitter' },
        { 'which-key.nvim', 'which-key' },
        { 'plenary.nvim', 'plenary' },
    }
    for _, case in ipairs(cases) do
        local dir = h.plugin_dir({ [case[2]] = 'return {}', unrelated = 'return {}' })
        h.eq(main_module.find(dir, { case[1] }), case[2], case[1])
    end
end)

test('matches a single-file module', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/lua', 'p')
    vim.fn.writefile({ 'return {}' }, dir .. '/lua/solo.lua')
    vim.fn.mkdir(dir .. '/lua/extra', 'p')
    h.eq(main_module.find(dir, { 'solo.nvim' }), 'solo')
end)

test('tries candidate names in order', function()
    local dir = h.plugin_dir({ first = 'return {}', second = 'return {}' })
    h.eq(main_module.find(dir, { 'nothing', 'second.nvim', 'first' }), 'second')
end)

test('a lone module wins when no name matches', function()
    local dir = h.plugin_dir({ onlyone = 'return {}' })
    h.eq(main_module.find(dir, { 'different-name' }), 'onlyone')
end)

test('several modules and no match is an error that names them', function()
    local dir = h.plugin_dir({ alpha = 'return {}', beta = 'return {}' })
    local module, err = main_module.find(dir, { 'gamma' })
    h.eq(module, nil)
    h.ok(err and err:find('alpha, beta', 1, true), err)
    h.ok(err and err:find('set `main`', 1, true), err)
end)

test('a plugin without lua/ is an error', function()
    local module, err = main_module.find(vim.fn.tempname(), { 'anything' })
    h.eq(module, nil)
    h.ok(err and err:find('no lua/ directory', 1, true), err)
end)

return tests
