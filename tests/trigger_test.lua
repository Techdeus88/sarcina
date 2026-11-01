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
        '            cmd_ran = g.trg_cmd_ran, key_pressed = g.trg_key_pressed, order = _G.trg_order,',
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

-- Writes a spec file whose configs log their plugin name, in load order, to _G.trg_order.
local function write_specs(plugins)
    local specs = vim.fn.stdpath('config') .. '/lua/plugins'
    vim.fn.mkdir(specs, 'p')
    local file = specs .. '/trigger_child.lua'
    local lines = {
        'local function log(name) return function() _G.trg_order = _G.trg_order or {}; table.insert(_G.trg_order, name) end end',
        'return {',
    }
    vim.list_extend(lines, plugins)
    table.insert(lines, '}')
    vim.fn.writefile(lines, file)
    return file
end

local function installed(name, plugin_file)
    local dir = paths.install(name)
    vim.fn.mkdir(dir .. '/plugin', 'p')
    if plugin_file then
        vim.fn.writefile({ plugin_file }, dir .. '/plugin/' .. name:gsub('%.nvim$', '') .. '.lua')
    end
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

test('a triggered plugin loads its now, later and triggered dependencies before itself', function()
    for _, name in ipairs({ 'trgdnow.nvim', 'trgdlater.nvim', 'trgdtrig.nvim' }) do
        installed(name)
    end
    installed('trgdmain.nvim', "vim.api.nvim_create_user_command('TrgDepCmd', function() end, {})")
    local seen = run_child(
        { "        vim.cmd('TrgDepCmd')", '        settle()' },
        nil,
        function()
            return write_specs({
                "    { name = 'trgdnow.nvim', repo = 'x/trgdnow', load = 'now', config = log('now') },",
                "    { name = 'trgdlater.nvim', repo = 'x/trgdlater', config = log('later') },",
                "    { name = 'trgdtrig.nvim', repo = 'x/trgdtrig', event = 'User TrgDepEvent', config = log('triggered') },",
                "    { name = 'trgdmain.nvim', repo = 'x/trgdmain', cmd = 'TrgDepCmd', config = log('main'),",
                "        deps = { 'trgdnow.nvim', 'trgdlater.nvim', 'trgdtrig.nvim' } },",
            })
        end
    )
    h.eq(seen.order, { 'now', 'later', 'triggered', 'main' })
end)

test('a file argument wakes a filetype trigger only after its later dependency has loaded', function()
    installed('trgelater.nvim')
    installed('trgeft.nvim')
    local seen = run_child(
        {},
        lua_file(),
        function()
            return write_specs({
                "    { name = 'trgelater.nvim', repo = 'x/trgelater', config = log('later') },",
                "    { name = 'trgeft.nvim', repo = 'x/trgeft', ft = 'lua', config = log('ft'), deps = { 'trgelater.nvim' } },",
            })
        end
    )
    h.eq(seen.order, { 'later', 'ft' })
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

    test('on a very first launch a triggered plugin still loads after its dependencies', function()
        local now = repo('trgfnow', '-- now')
        local dep = repo('trgfdep', '-- dep')
        local main = repo('trgfft', '-- ft')
        local seen = run_child(
            {},
            lua_file(),
            function()
                return write_specs({
                    string.format(
                        "    { name = 'trgfnow.nvim', repo = %q, load = 'now', config = log('now') },",
                        now
                    ),
                    string.format("    { name = 'trgfdep.nvim', repo = %q, config = log('later') },", dep),
                    string.format(
                        "    { name = 'trgfft.nvim', repo = %q, ft = 'lua', config = log('ft'), deps = { 'trgfnow.nvim', 'trgfdep.nvim' } },",
                        main
                    ),
                })
            end
        )
        h.eq(seen.order, { 'now', 'later', 'ft' })
    end)
end

return tests
