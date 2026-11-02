-- sarcina/executors.lua
-- Task executors, keyed by task type. Each is `function(job, done, report)`.
-- Call `done(ok, msg)` exactly once and `report(line)` to publish live output.
-- A task that does real work, such as a clone or a build that is not up to date, sets `job.working` and
-- calls `report()` with no line to say so.
-- The runner in tasks.lua owns every status change, so executors never touch the UI state.

local lock = require('sarcina.lock')
local paths = require('sarcina.paths')

local uv = vim.uv

local M = {}

-- Git must never ask a question. With a terminal it would read the answer from the one Neovim is using, and a
-- repo it cannot find (a typo in owner/repo makes GitHub ask for a username) would hold every task behind the
-- install barrier. A transfer that stays under 1 KB/s for a minute is dropped, and no git command runs
-- longer than `git_timeout` ms, a field so that tests can shorten it.
M.git_timeout = 600000
local GIT_ENV = { GIT_TERMINAL_PROMPT = '0', GCM_INTERACTIVE = 'never' }
local SLOW = { '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=60' }

-- `git [-C dir] <args>` for a command that talks to a remote, with what it needs not to hang.
local function remote_git(args, dir)
    local cmd = { 'git' }
    if dir then vim.list_extend(cmd, { '-C', dir }) end
    vim.list_extend(cmd, SLOW)
    return vim.list_extend(cmd, args)
end

local function remote_opts() return { env = GIT_ENV, timeout = M.git_timeout } end

local function last_line(data)
    local last
    for line in data:gmatch('[^\r\n]+') do
        last = line
    end
    return last
end

--- The URL a `repo` is cloned from: `owner/repo` is on GitHub, and anything else is used as it is.
local function clone_url(repo)
    if repo:match('^%w[%w_.-]*/[%w_.-]+$') then return 'https://github.com/' .. repo end
    return repo
end
M.clone_url = clone_url

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
        if res.code == 0 and (res.signal or 0) == 0 then
            cb(true)
        elseif res.code == 124 and spawn_opts.timeout then
            cb(false, cmd[1] .. ' timed out')
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

-- Makes the help of the plugin in `dir` findable with :help, which needs a doc/tags next to its help files. A
-- doc/tags that is already there is left alone unless `force`, so one the plugin commits is never overwritten.
local function make_helptags(dir, force)
    local doc = dir .. '/doc'
    if not uv.fs_stat(doc) or (not force and uv.fs_stat(doc .. '/tags')) then return end
    pcall(vim.cmd, 'helptags ' .. vim.fn.fnameescape(doc))
end

-- Runs `git -C dir <args>` and calls `cb(ok, text)` on the main loop: its output, or when it failed the last
-- line it printed. `network` is for a command that talks to a remote.
local function git(dir, args, cb, network)
    local cmd = { 'git', '-C', dir }
    if network then vim.list_extend(cmd, SLOW) end
    vim.list_extend(cmd, args)
    local opts = vim.tbl_extend('force', { text = true }, network and remote_opts() or {})
    local spawned = pcall(vim.system, cmd, opts, function(res)
        vim.schedule(function()
            if res.code == 0 and (res.signal or 0) == 0 then return cb(true, vim.trim(res.stdout or '')) end
            if network and res.code == 124 then return cb(false, 'git timed out') end
            local said = last_line(res.stderr or '') or last_line(res.stdout or '')
            cb(false, said or string.format('git exited with code %d', res.code))
        end)
    end)
    if not spawned then vim.schedule(function() cb(false, 'git is not available') end) end
end

local function short(commit) return commit:sub(1, 7) end

-- Makes `dir` sit at `commit`: it is fetched when the clone does not have it, then the branch is moved there,
-- so the branch still tracks its upstream and a later update moves on from it.
local function pin(dir, commit, cb)
    git(dir, { 'cat-file', '-e', commit .. '^{commit}' }, function(have)
        local function reset() git(dir, { 'reset', '--hard', commit }, cb) end
        if have then return reset() end
        git(dir, { 'fetch', '--depth', '1', 'origin', commit }, function(fetched, err)
            if not fetched then return cb(false, err) end
            reset()
        end, true)
    end)
end

function M.git_clone(job, done, report)
    local spec = job.spec
    if not spec.repo then return done(false, 'no repo') end
    local dest = paths.install(job.plugin)
    if uv.fs_stat(dest) then return done(true, 'already installed') end
    job.working = true
    report()
    local staging = paths.staging(job.plugin)
    vim.fn.mkdir(vim.fn.fnamemodify(staging, ':h'), 'p')
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ':h'), 'p')
    local cmd = remote_git({ 'clone', '--depth', '1', '--progress', clone_url(spec.repo), staging })
    local function fail(err)
        vim.fn.delete(staging, 'rf')
        done(false, err)
    end
    local function move()
        local moved, move_err = uv.fs_rename(staging, dest)
        if not moved then return fail('atomic move failed: ' .. tostring(move_err)) end
        make_helptags(dest)
        lock.mark(job.plugin, dest)
        done(true)
    end
    run_cmd(cmd, remote_opts(), report, function(ok, err)
        vim.schedule(function()
            if not ok then return fail(err) end
            -- The lock file names the commit this plugin was last installed or updated at.
            local locked = lock.get(job.plugin)
            if not locked then return move() end
            git(staging, { 'rev-parse', 'HEAD' }, function(read, head)
                if read and head == locked then return move() end
                pin(staging, locked, function(pinned, why)
                    if not pinned then
                        return fail(
                            string.format('locked commit %s is not available: %s', short(locked), why)
                        )
                    end
                    move()
                end)
            end)
        end)
    end)
end

-- `check` or `update` of a plugin: fetches what its remote has, compares that with `HEAD`, and for `update`
-- (`spec.apply`) moves there. Its note says what happened. A plugin with changes of its own is left as it is.
function M.git_update(job, done, report)
    local spec = job.spec
    local dir = paths.install(job.plugin)
    if not uv.fs_stat(dir) then return done(true, 'not installed') end
    job.working = true
    report()
    run_cmd(
        remote_git({ 'fetch', '--depth', '1', '--progress', 'origin' }, dir),
        remote_opts(),
        report,
        function(fetched, err)
            vim.schedule(function()
                if not fetched then return done(false, err) end
                git(dir, { 'rev-parse', 'HEAD', '@{u}' }, function(read, out)
                    local head, upstream = out:match('^(%x+)%s+(%x+)')
                    if not read or not head then return done(false, read and 'no upstream branch' or out) end
                    if spec.apply then lock.mark(job.plugin, dir) end
                    if head == upstream then return done(true, 'up to date') end
                    local change = short(head) .. ' → ' .. short(upstream)
                    if not spec.apply then return done(true, 'update available ' .. change) end
                    git(dir, { 'status', '--porcelain', '--untracked-files=no' }, function(_, changes)
                        if changes ~= '' then return done(true, 'skipped: local changes') end
                        git(dir, { 'reset', '--hard', '@{u}' }, function(moved, why)
                            if not moved then return done(false, why) end
                            -- Help the update brought is findable too, unless the plugin commits its own tags.
                            git(dir, { 'ls-files', 'doc/tags' }, function(_, tracked)
                                if tracked == '' then make_helptags(dir, true) end
                                done(true, change)
                            end)
                        end)
                    end)
                end)
            end)
        end
    )
end

function M.make(job, done, report)
    local cwd = job.spec.cwd or paths.install(job.plugin)
    run_cmd({ 'make' }, { cwd = cwd }, report, done)
end

-- Runs `spec.cmd` through the shell, in the plugin directory unless `spec.cwd` says otherwise.
function M.shell(job, done, report)
    local cwd = job.spec.cwd or paths.install(job.plugin)
    local shell = vim.fn.has('win32') == 1 and { 'cmd.exe', '/c' } or { 'sh', '-c' }
    run_cmd(vim.list_extend(shell, { job.spec.cmd }), { cwd = cwd }, report, done)
end

-- ftdetect scripts only run when filetype detection is set up, at startup. A plugin that loads later has to run
-- them itself, in the group they belong to.
local function source_ftdetect(dir)
    vim.cmd('augroup filetypedetect')
    pcall(function()
        for _, ext in ipairs({ 'vim', 'lua' }) do
            for _, file in ipairs(vim.fn.globpath(dir, 'ftdetect/*.' .. ext, false, true)) do
                vim.cmd.source(vim.fn.fnameescape(file))
            end
        end
    end)
    vim.cmd('augroup END')
end

local sourced = {} -- plugin directory -> true once its plugin/ files were sourced, or Neovim will source them

-- Puts the plugin on the runtimepath and, once the UI is up, sources its plugin/ files, once. `source = false`
-- only puts it on the runtimepath, so a build can require its modules before the plugin has run: a plugin
-- that loads a binary from plugin/ cannot run before its build has made the binary. Returns false and why
-- when the plugin directory is missing.
local function add_to_rtp(name, source)
    local path = paths.install(name)
    if not uv.fs_stat(path) then return false, 'plugin directory missing: ' .. path end
    local dirs = { path }
    if uv.fs_stat(path .. '/after') then table.insert(dirs, path .. '/after') end
    local rtp = vim.opt.rtp:get() --[[@as string[] ]]
    if not vim.tbl_contains(rtp, path) then
        -- Like a start/ package: the plugin joins the runtimepath, its after/ dir goes behind it.
        for _, dir in ipairs(dirs) do
            vim.opt.rtp:append(dir)
        end
        -- Before VimEnter, Neovim's own startup pass sources plugin/ and after/plugin from the rtp.
        sourced[path] = vim.v.vim_did_enter == 0 or nil
        make_helptags(path)
    end
    if source ~= false and vim.v.vim_did_enter == 1 and not sourced[path] then
        sourced[path] = true
        for _, dir in ipairs(dirs) do
            source_ftdetect(dir)
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

-- Defines the mappings of the `keys` entries that have an rhs.
function M.keymaps(job, done)
    for _, map in ipairs(job.spec.keys) do
        require('sarcina.keys').set(map)
    end
    done(true)
end

-- Hands the triggers to the scheduler; the deferred rtp/config/after tasks run when one fires.
function M.trigger(job, done)
    local scheduler = require('sarcina.scheduler')
    scheduler.register(job.plugin, job.spec)
    done(true, 'waiting for ' .. scheduler.describe(job.spec.triggers))
end

-- `opts` may be a function(plugin, opts): it returns the table, or fills in the empty one it is given.
local function resolve_opts(opts, plugin)
    if type(opts) ~= 'function' then return opts end
    local given = {}
    local returned = opts(plugin, given)
    if returned == nil then return given end
    return returned
end

-- A build function that declares a second parameter is async: it gets `done(ok, msg)` and the job runs
-- until it is called. Any other function, and every other lua task, finishes when it returns.
local function takes_done(job, fn) return job.id == 'build' and debug.getinfo(fn, 'u').nparams >= 2 end

-- Calls `spec.fn`, or the compiled `spec.script`, as fn({ name, dir }, opts).
function M.lua(job, done)
    local spec = job.spec
    local fn = spec.fn
    if not fn then
        local err
        fn, err = loadstring(spec.script or '')
        if not fn then return done(false, err) end
    end
    local plugin = { name = job.plugin, dir = paths.install(job.plugin) }
    if spec.fn and takes_done(job, fn) then
        local ok, err = pcall(fn, plugin, done)
        if not ok then done(false, err) end
        return
    end
    local ok, err = pcall(function() fn(plugin, resolve_opts(spec.opts, plugin)) end)
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

-- `needs_plugin` puts the plugin on the runtimepath first, for code that requires its modules. Its plugin/
-- files wait for the `rtp` task.
local function per_commit(exec, needs_plugin)
    return function(job, done, report)
        if not job.spec.per_commit then return exec(job, done, report) end
        local record = paths.install(job.plugin) .. '/.git/sarcina-' .. job.id
        head_commit(job.plugin, function(commit)
            if commit and read_record(record) == commit then return done(true, 'up to date') end
            job.working = true
            report()
            if needs_plugin then add_to_rtp(job.plugin, false) end
            exec(job, function(ok, msg)
                if ok and commit then write_record(record, commit) end
                done(ok, msg)
            end, report)
        end)
    end
end

M.lua = per_commit(M.lua, true)
M.cmd = per_commit(M.cmd)
M.shell = per_commit(M.shell)
M.make = per_commit(M.make)

return M
