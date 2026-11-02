local executors = require('sarcina.executors')
local h = require('helpers')
local paths = require('sarcina.paths')

local tests = {}
local function test(name, fn) table.insert(tests, { name, fn }) end

if vim.fn.executable('sh') == 0 then return {} end

-- Puts a `git` that runs `body` first on the path, and returns the file it logs to. `restore()` undoes it.
local function fake_git(body)
    local bin, log = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.mkdir(bin, 'p')
    local script = bin .. '/git'
    local lines =
        { '#!/bin/sh', 'echo "PROMPT=$GIT_TERMINAL_PROMPT GCM=$GCM_INTERACTIVE ARGS=$*" >> "' .. log .. '"' }
    vim.fn.writefile(vim.list_extend(lines, vim.split(body, '\n')), script)
    vim.uv.fs_chmod(script, 493)
    local old = vim.env.PATH
    vim.env.PATH = bin .. ':' .. old
    return log, function() vim.env.PATH = old end
end

local REFUSES = 'echo "fatal: fake git says no" >&2; exit 128'

local function logged(log) return table.concat(vim.fn.readfile(log), '\n') end

test('a clone never asks a question, and drops a transfer that has stalled', function()
    local log, restore = fake_git(REFUSES)
    local ok, err = pcall(function()
        local install = { id = 'install', type = 'git_clone', repo = 'x/refused', phase = 'install' }
        h.run({ { name = 'refused.nvim', tasks = { install } } })
        h.eq(h.job('refused.nvim', 'install').error, 'fatal: fake git says no')
        local said = logged(log)
        h.ok(said:find('PROMPT=0 GCM=never', 1, true), said)
        h.ok(said:find('-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 clone', 1, true), said)
    end)
    restore()
    assert(ok, err)
end)

-- Answers the lookup of the remote and the commit of the plugin, says the plugin has no changes, and refuses the rest.
local LOOKS_BEHIND = table.concat({
    'case "$*" in',
    '*ls-remote*) printf "' .. string.rep('a', 40) .. '\\tHEAD\\n";;',
    '*rev-parse*) echo ' .. string.rep('b', 40) .. ';;',
    '*status*) ;;',
    '*) ' .. REFUSES .. ';;',
    'esac',
}, '\n')

test('the lookup of a check and the fetch of an update never ask a question either', function()
    vim.fn.mkdir(paths.install('looky.nvim'), 'p')
    vim.fn.mkdir(paths.install('fetchy.nvim'), 'p')
    local log, restore = fake_git(LOOKS_BEHIND)
    local ok, err = pcall(function()
        local function plan(id, apply)
            return { { id = id, type = 'git_update', apply = apply, phase = 'install' } }
        end
        h.run({ { name = 'looky.nvim', tasks = plan('check', false) } })
        local looked = logged(log)
        h.ok(looked:find('PROMPT=0 GCM=never', 1, true), looked)
        h.ok(looked:find('lowSpeedLimit=1000 -c http.lowSpeedTime=60 ls-remote origin HEAD', 1, true), looked)
        h.eq(h.job('looky.nvim', 'check').note, 'update available bbbbbbb → aaaaaaa')
        h.run({ { name = 'fetchy.nvim', tasks = plan('update', true) } })
        h.eq(h.job('fetchy.nvim', 'update').status, 'failed')
        local fetched = logged(log)
        h.ok(fetched:find('PROMPT=0 GCM=never', 1, true), fetched)
        h.ok(
            fetched:find(
                'lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch --depth 1 --progress origin HEAD',
                1,
                true
            ),
            fetched
        )
    end)
    restore()
    assert(ok, err)
end)

test('a git that never answers is stopped, and the install fails instead of holding every task', function()
    local _, restore = fake_git('exec sleep 8') -- exec, so that the process the timeout kills is the one holding the pipes
    local before = executors.git_timeout
    executors.git_timeout = 300
    local ok, err = pcall(function()
        local started = vim.uv.hrtime()
        local install = { id = 'install', type = 'git_clone', repo = 'x/hangs', phase = 'install' }
        h.run({ { name = 'hangs.nvim', tasks = { install } } })
        h.eq(h.job('hangs.nvim', 'install').error, 'git timed out')
        h.ok((vim.uv.hrtime() - started) / 1e9 < 5, 'it waited for the git that never answered')
        h.eq(vim.uv.fs_stat(paths.install('hangs.nvim')), nil)
    end)
    executors.git_timeout = before
    restore()
    assert(ok, err)
end)

return tests
