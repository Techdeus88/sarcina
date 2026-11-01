local h = require('helpers')
local keys = require('sarcina.keys')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

test(
    'a bare string is an lhs with no rhs',
    function() h.eq(keys.parse('gd'), { lhs = 'gd', mode = 'n', opts = { silent = true } }) end
)

test('the second entry is the rhs, not the mode', function()
    local key = keys.parse({ '<leader>uc', '<cmd>CodeDiff<cr>', desc = 'Toggle CodeDiff' })
    h.eq(key.lhs, '<leader>uc')
    h.eq(key.rhs, '<cmd>CodeDiff<cr>')
    h.eq(key.mode, 'n')
    h.eq(key.opts, { silent = true, desc = 'Toggle CodeDiff' })
end)

test('lhs, rhs and mode can be named fields', function()
    local key =
        keys.parse({ lhs = '<leader>ff', rhs = 'x', mode = { 'n', 'v' }, silent = false, nowait = true })
    h.eq(
        key,
        { lhs = '<leader>ff', rhs = 'x', mode = { 'n', 'v' }, opts = { silent = false, nowait = true } }
    )
end)

test('set defines the mapping for an entry with an rhs and ignores one without', function()
    keys.set({ '<F4>', '<cmd>echo 1<cr>', desc = 'Four' })
    keys.set('<F3>')
    local mapped = vim.fn.maparg('<F4>', 'n', false, true)
    h.eq(mapped.rhs, '<cmd>echo 1<cr>')
    h.eq(mapped.desc, 'Four')
    h.eq(vim.fn.maparg('<F3>', 'n'), '')
    pcall(vim.keymap.del, 'n', '<F4>')
end)

return tests
