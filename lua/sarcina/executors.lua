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

local function source_plugin_files(dir)
    for _, ext in ipairs({ 'vim', 'lua' }) do
        for _, file in ipairs(vim.fn.globpath(dir, 'plugin/**/*.' .. ext, false, true)) do
            vim.cmd.source(vim.fn.fnameescape(file))
        end
    end
end

function M.git_clone(job, done, report)
    local spec = job.spec
    if not spec.repo then return done(false, 'no repo') end
    local dest = spec.dest or paths.install(job.plugin)
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
    local cwd = job.spec.cwd or paths.install(job.plugin)
    run_cmd({ 'make' }, { cwd = cwd }, report, done)
end

-- Returns false and why when the plugin directory is missing.
local function add_to_rtp(name)
    local path = paths.install(name)
    if not uv.fs_stat(path) then return false, 'plugin directory missing: ' .. path end
    local rtp = vim.opt.rtp:get() --[[@as string[] ]]
    if vim.tbl_contains(rtp, path) then return true end
    -- Like a start/ package: the plugin joins the runtimepath, its after/ dir goes behind it.
    local dirs = { path }
    if uv.fs_stat(path .. '/after') then table.insert(dirs, path .. '/after') end
    for _, dir in ipairs(dirs) do
        vim.opt.rtp:append(dir)
    end
    -- Before VimEnter, Neovim's own startup pass sources plugin/ and after/plugin from the rtp.
    if vim.v.vim_did_enter == 1 then
        for _, dir in ipairs(dirs) do
            source_plugin_files(dir)
        end
    end
    return true
end

function M.rtp(job, done) done(add_to_rtp(job.plugin)) end

-- Runs `spec.cmd` as an Ex command. The plugin joins the runtimepath first, since its commands come
-- from its plugin/ files; a hook that runs before the clone has no directory to add yet.
function M.cmd(job, done)
    add_to_rtp(job.plugin)
    local ok, err = pcall(function() vim.cmd(job.spec.cmd) end)
    done(ok, err)
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
    local plugin = { name = job.plugin, dir = paths.install(job.plugin) }
    local ok, err = pcall(fn, plugin, spec.opts)
    if ok then
        done(true)
    else
        done(false, err)
    end
end

-- A task with `per_commit` runs only when the plugin's HEAD differs from the commit it last succeeded
-- at. The record sits in the plugin's .git, so a fresh clone has none and a failed run is retried.

-- Calls cb(commit) on the main loop; commit is nil when the plugin has no readable HEAD.
local function head_commit(name, cb)
    local cmd = { 'git', '-C', paths.install(name), 'rev-parse', 'HEAD' }
    local spawned = pcall(vim.system, cmd, { text = true }, function(res)
        vim.schedule(function() cb(res.code == 0 and vim.trim(res.stdout) or nil) end)
    end)
    if not spawned then vim.schedule(cb) end
end

local function read_record(path)
    local file = io.open(path, 'r')
    if not file then return nil end
    local commit = file:read('*l')
    file:close()
    return commit
end

local function write_record(path, commit)
    local file = io.open(path, 'w')
    if not file then return end
    file:write(commit, '\n')
    file:close()
end

local function per_commit(exec)
    return function(job, done, report)
        if not job.spec.per_commit then return exec(job, done, report) end
        local record = paths.install(job.plugin) .. '/.git/sarcina-' .. job.id
        head_commit(job.plugin, function(commit)
            if commit and read_record(record) == commit then return done(true, 'up to date') end
            exec(job, function(ok, msg)
                if ok and commit then write_record(record, commit) end
                done(ok, msg)
            end, report)
        end)
    end
end

for _, kind in ipairs({ 'lua', 'cmd', 'make' }) do
    M[kind] = per_commit(M[kind])
end

return M
