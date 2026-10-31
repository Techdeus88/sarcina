-- sarcina/executors.lua
-- Task executors, keyed by task type. Each is `function(job, done, report)`.
-- Call `done(ok, msg)` exactly once and `report(line)` to publish live output.
-- The runner in tasks.lua owns every status change, so executors never touch the UI state.

local paths = require('sarcina.paths')

local uv = vim.uv

local M = {}

local function last_line(data)
    local last
    for line in data:gmatch('[^\r\n]+') do
        last = line
    end
    return last
end

local function clone_url(repo)
    if repo:match('^%w[%w_.-]*/[%w_.-]+$') then return 'https://github.com/' .. repo end
    return repo
end

-- cb runs in a fast event, so it must vim.schedule before using the API.
local function run_cmd(cmd, opts, report, cb)
    local tail
    local function on_output(_, data)
        local line = data and last_line(data)
        if line then
            tail = line
            report(line)
        end
    end
    local spawn_opts =
        vim.tbl_extend('force', { text = true, stdout = on_output, stderr = on_output }, opts or {})
    local spawned, err = pcall(vim.system, cmd, spawn_opts, function(res)
        if res.code == 0 then
            cb(true)
        else
            cb(false, tail or string.format('%s exited with code %d', cmd[1], res.code))
        end
    end)
    if not spawned then cb(false, err) end
end

local function source_plugin_files(path)
    for _, ext in ipairs({ 'vim', 'lua' }) do
        for _, file in ipairs(vim.fn.globpath(path, 'plugin/**/*.' .. ext, false, true)) do
            vim.cmd.source(vim.fn.fnameescape(file))
        end
    end
end

function M.git_clone(job, done, report)
    local spec = job.spec
    if not spec.repo then return done(false, 'no repo') end
    local dest = spec.dest or paths.install(job.plugin, spec.opt)
    if uv.fs_stat(dest) then return done(true, 'already installed') end
    local staging = paths.staging(job.plugin)
    vim.fn.mkdir(vim.fn.fnamemodify(staging, ':h'), 'p')
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ':h'), 'p')
    local cmd = { 'git', 'clone', '--depth', '1', '--progress', clone_url(spec.repo), staging }
    run_cmd(cmd, nil, report, function(ok, err)
        vim.schedule(function()
            if not ok then
                vim.fn.delete(staging, 'rf')
                return done(false, err)
            end
            local moved, move_err = uv.fs_rename(staging, dest)
            if not moved then
                vim.fn.delete(staging, 'rf')
                return done(false, 'atomic move failed: ' .. tostring(move_err))
            end
            done(true)
        end)
    end)
end

function M.make(job, done, report)
    local cwd = job.spec.cwd or paths.install(job.plugin, job.spec.opt)
    run_cmd({ 'make' }, { cwd = cwd }, report, done)
end

function M.rtp(job, done)
    local path = paths.install(job.plugin, job.spec.opt)
    if not uv.fs_stat(path) then return done(false, 'plugin directory missing: ' .. path) end
    local rtp = vim.opt.rtp:get() --[[@as string[] ]]
    if vim.tbl_contains(rtp, path) then return done(true) end
    vim.opt.rtp:append(path)
    if vim.v.vim_did_enter == 1 then source_plugin_files(path) end
    done(true)
end

-- Hands the triggers to the scheduler; the deferred rtp/config/after tasks run when one fires.
function M.trigger(job, done)
    local scheduler = require('sarcina.scheduler')
    scheduler.register(job.plugin, job.spec)
    done(true, 'waiting for ' .. scheduler.describe(job.spec.triggers))
end

-- Calls `spec.fn`, or the compiled `spec.script`, as fn({ name, dir }, spec.opts).
function M.lua(job, done)
    local spec = job.spec
    local fn = spec.fn
    if not fn then
        local err
        fn, err = loadstring(spec.script or '')
        if not fn then return done(false, err) end
    end
    local plugin = { name = job.plugin, dir = paths.install(job.plugin, spec.opt) }
    local ok, err = pcall(fn, plugin, spec.opts)
    if ok then
        done(true)
    else
        done(false, err)
    end
end

return M
