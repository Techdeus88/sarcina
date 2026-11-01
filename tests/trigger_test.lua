local h = require('helpers')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- Four installed plugins, one per trigger. Each flags its own load, and the event and filetype ones add a
-- handler of their own when they load, which a correct replay runs for the buffer that woke them.
local function fixtures()
    local plugin = function(name, body)
        local dir = paths.install(name)
        vim.fn.mkdir(dir .. '/plugin', 'p')
        vim.fn.writefile({ body }, dir .. '/plugin/' .. name:gsub('%.nvim$', '') .. '.lua')
    end
    plugin(
        'trgev.nvim',
        "vim.api.nvim_create_autocmd('BufRead', { callback = function() vim.g.trg_ev_replayed = true end })"
    )
    plugin(
        'trgft.nvim',
        "vim.api.nvim_create_autocmd('FileType', { pattern = 'lua', callback = function() vim.g.trg_ft_replayed = true end })"
    )
    plugin(
        'trgcmd.nvim',
        "vim.api.nvim_create_user_command('TrgCmd', function() vim.g.trg_cmd_ran = true end, {})"
    )
    plugin('trgkey.nvim', '')
    local specs = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(specs, 'p')
    local file = specs .. '/trigger_child.lua'
    vim.fn.writefile({
        'return {',
        "    { name = 'trgev.nvim', repo = 'x/trgev', event = 'BufRead', config = function() vim.g.trg_ev_loaded = true end },",
        "    { name = 'trgft.nvim', repo = 'x/trgft', ft = 'lua', config = function() vim.g.trg_ft_loaded = true end },",
        "    { name = 'trgcmd.nvim', repo = 'x/trgcmd', cmd = 'TrgCmd', config = function() vim.g.trg_cmd_loaded = true end },",
        "    { name = 'trgkey.nvim', repo = 'x/trgkey', keys = { { '<F5>', '<cmd>let g:trg_key_pressed = 1<cr>' } },",
        '        config = function() vim.g.trg_key_loaded = true end },',
        '}',
    }, file)
    return file
end

-- Starts Neovim for real, optionally with a file argument, runs `steps` once startup is done, and reports
-- which plugins loaded and which replays ran.
local function run_child(steps, argument, build_specs)
    local spec = (build_specs or fixtures)()
    local script = vim.fn.tempname() .. '.lua'
    local lines = {
        string.format('vim.opt.rtp:prepend(%q)', root),
        "require('sarcina').setup()",
        'local function settle()',
        "    require('sarcina.tasks').wait(5000)",
        '    vim.wait(300)',
        "    require('sarcina.tasks').wait(5000)",
        'end',
        "vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()",
        '    vim.defer_fn(function()',
        '        settle()',
    }
    vim.list_extend(lines, steps)
    vim.list_extend(lines, {
        '        local g = vim.g',
        '        io.stdout:write(vim.json.encode({',
        '            ev = g.trg_ev_loaded, ft = g.trg_ft_loaded, cmd = g.trg_cmd_loaded, key = g.trg_key_loaded,',
        '            ev_replayed = g.trg_ev_replayed, ft_replayed = g.trg_ft_replayed,',
        '            cmd_ran = g.trg_cmd_ran, key_pressed = g.trg_key_pressed,',
        '        }))',
        '        vim.cmd.qa({ bang = true })',
        '    end, 200)',
        'end })',
    })
    vim.fn.writefile(lines, script)
    local command = { vim.v.progpath, '--headless', '-i', 'NONE', '-u', script }
    if argument then table.insert(command, argument) end
    local res = vim.system(command, { text = true }):wait(20000)
    vim.fn.delete(spec)
    h.eq(res.code, 0, res.stderr)
    return vim.json.decode(res.stdout)
end

local function lua_file()
    local path = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ "print('hello')" }, path)
    return path
end

test('starting with a file wakes the event and filetype triggers of the first buffer', function()
    local seen = run_child({}, lua_file())
    h.eq(seen.ev, true)
    h.eq(seen.ft, true)
    h.eq({ seen.ev_replayed, seen.ft_replayed }, { true, true })
end)

test('a buffer opened after startup wakes the event and filetype triggers, and replays them', function()
    local path = lua_file()
    local seen = run_child({ string.format("        vim.cmd('edit ' .. %q)", path), '        settle()' })
    h.eq({ seen.ev, seen.ft, seen.ev_replayed, seen.ft_replayed }, { true, true, true, true })
end)

test('starting without a file loads no event or filetype plugin', function()
    local seen = run_child({})
    h.eq({ seen.ev, seen.ft }, {})
end)

test('a command trigger loads its plugin, then runs the command', function()
    local seen = run_child({ "        vim.cmd('TrgCmd')", '        settle()' })
    h.eq({ seen.cmd, seen.cmd_ran }, { true, true })
end)

test('a key trigger loads its plugin and the key reaches its mapping', function()
    local seen = run_child({
        "        vim.api.nvim_feedkeys(vim.keycode('<F5>'), 'x', false)",
        '        settle()',
        "        vim.api.nvim_feedkeys('', 'x', false)",
    })
    h.eq({ seen.key, seen.key_pressed }, { true, 1 })
end)

if vim.fn.executable('git') == 1 then
    -- A local git repo holding one plugin file, so the child can clone it for real.
    local function repo(name, body)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. '/plugin', 'p')
        vim.fn.writefile({ body }, dir .. '/plugin/' .. name .. '.lua')
        vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
        vim.fn.system({ 'git', '-C', dir, 'add', '-A' })
        vim.fn.system({
            'git',
            '-C',
            dir,
            '-c',
            'user.name=t',
            '-c',
            'user.email=t@t',
            'commit',
            '-q',
            '-m',
            'init',
        })
        return dir
    end

    test('on a very first launch the triggers still catch up with the first buffer', function()
        local ev = repo(
            'trgnewev',
            "vim.api.nvim_create_autocmd('BufRead', { callback = function() vim.g.trg_ev_replayed = true end })"
        )
        local ft = repo(
            'trgnewft',
            "vim.api.nvim_create_autocmd('FileType', { pattern = 'lua', callback = function() vim.g.trg_ft_replayed = true end })"
        )
        local seen = run_child({}, lua_file(), function()
            local specs = vim.fn.stdpath('config') .. '/lua/plugins'
            vim.fn.mkdir(specs, 'p')
            local file = specs .. '/trigger_child.lua'
            vim.fn.writefile({
                'return {',
                string.format(
                    "    { name = 'trgnewev.nvim', repo = %q, event = 'BufRead', config = function() vim.g.trg_ev_loaded = true end },",
                    ev
                ),
                string.format(
                    "    { name = 'trgnewft.nvim', repo = %q, ft = 'lua', config = function() vim.g.trg_ft_loaded = true end },",
                    ft
                ),
                '}',
            }, file)
            return file
        end)
        h.eq({ seen.ev, seen.ft, seen.ev_replayed, seen.ft_replayed }, { true, true, true, true })
    end)
end

return tests
