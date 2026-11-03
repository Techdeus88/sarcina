local h = require('helpers')
local json = require('sarcina.json')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local VALUE = {
    ['b.nvim'] = { commit = 'abc', pin = 'branch:feature/x' },
    ['a.nvim'] = { commit = 'def', ms = 1.5, list = { 1, 2 }, none = {} },
}

test('encode sorts the keys and indents each level two spaces, slashes left as they are', function()
    h.eq(
        json.encode(VALUE),
        table.concat({
            '{',
            '  "a.nvim": {',
            '    "commit": "def",',
            '    "list": [',
            '      1,',
            '      2',
            '    ],',
            '    "ms": 1.5,',
            '    "none": []',
            '  },',
            '  "b.nvim": {',
            '    "commit": "abc",',
            '    "pin": "branch:feature/x"',
            '  }',
            '}',
        }, '\n')
    )
    h.eq(json.encode({}), '[]')
    h.eq(vim.json.decode(json.encode(VALUE)), vim.json.decode(vim.json.encode(VALUE)))
end)

test('encode writes what vim.json.encode writes with indent and sort_keys, where Neovim has them', function()
    local ok, text = pcall(vim.json.encode, VALUE, { indent = '  ', sort_keys = true })
    if not ok or not text:find('\n', 1, true) then return end
    h.eq(json.encode(VALUE), text)
end)

return tests
