-- sarcina/executors.lua
-- Task executors, keyed by task type. Each is `function(job, done, report)`.
-- Call `done(ok, msg)` exactly once and `report(line)` to publish live output.
-- A task that does real work, such as a clone or a build that is not up to date, sets `job.working` and
-- calls `report()` with no line to say so.
-- The runner in tasks.lua owns every status change, so executors never touch the UI state.

local lock = require('sarcina.lock')
local paths = require('sarcina.paths')
local pins = require('sarcina.pin')

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

-- Whether `head` is the commit `commit` names, which may be abbreviated.
local function is_commit(head, commit) return head:sub(1, #commit):lower() == commit:lower() end

local function verify(dir, commit, cb) git(dir, { 'rev-parse', '--verify', '-q', commit .. '^{commit}' }, cb) end

-- A server cannot look up an abbreviated commit, so the history comes down until the clone has it.
local function deepen(dir, cb)
    git(dir, { 'rev-parse', '--is-shallow-repository' }, function(_, shallow)
        local args = { 'fetch' }
        if shallow == 'true' then table.insert(args, '--unshallow') end
        git(dir, vim.list_extend(args, { 'origin', '+refs/heads/*:refs/remotes/origin/*' }), cb, true)
    end)
end

-- Makes `dir` sit at `commit`, in full or abbreviated: it is fetched when the clone does not have it, then the
-- branch is moved there, so the branch still tracks its upstream and a later update moves on from it.
local function fetch_commit(dir, commit, cb)
    local function reset(rev) git(dir, { 'reset', '--hard', rev }, cb) end
    verify(dir, commit, function(have, full)
        if have then return reset(full) end
        if #commit == 40 then
            return git(dir, { 'fetch', '--depth', '1', 'origin', commit }, function(fetched, err)
                if not fetched then return cb(false, err) end
                reset(commit)
            end, true)
        end
        deepen(dir, function(deepened, err)
            if not deepened then return cb(false, err) end
            verify(dir, commit, function(found, full_commit)
                if not found then return cb(false, 'the remote has no commit that starts with ' .. commit) end
                reset(full_commit)
            end)
        end)
    end)
end

-- Where the remote has what `pin` asks for (the default branch when there is none), as cb(true, target) or
-- cb(false, why). A target holds `sha` and the `ref` to fetch to get it, and for a version the `tag`; a commit
-- pin needs no lookup, so its target is the `commit` it names. `remote` is a URL, or 'origin' in a clone, and
-- git runs in `dir`.
local function find_target(dir, remote, pin, cb)
    if pin and pin.kind == 'commit' then return cb(true, { commit = pin.value }) end
    local kind, name = pin and pin.kind, pin and pin.value
    local head, tag = 'refs/heads/' .. tostring(name), 'refs/tags/' .. tostring(name)
    local args = { 'ls-remote' }
    local candidates
    if not pin then
        candidates = { 'HEAD' }
    elseif kind == 'branch' then
        candidates = { head }
    elseif kind == 'tag' then
        candidates = { tag }
    elseif kind == 'ref' then
        candidates = { head, tag }
    else
        table.insert(args, '--tags')
    end
    table.insert(args, remote)
    for _, ref in ipairs(candidates or {}) do
        table.insert(args, ref)
        if vim.startswith(ref, 'refs/tags/') then table.insert(args, ref .. '^{}') end
    end
    git(dir, args, function(ok, out)
        if not ok then return cb(false, out) end
        local refs = pins.refs(out)
        if kind == 'version' then
            local newest, sha = pins.newest(pin, refs)
            if not newest then return cb(false, 'no tag matches ' .. pins.describe(pin)) end
            return cb(true, { sha = sha, ref = 'refs/tags/' .. newest, tag = newest })
        end
        for _, ref in ipairs(candidates) do
            if refs[ref] then return cb(true, { sha = refs[ref], ref = ref }) end
        end
        if not pin then return cb(false, 'the remote has no HEAD') end
        cb(
            false,
            kind == 'ref' and name .. ' is not a branch or tag on the remote'
                or pins.describe(pin) .. ' not found on the remote'
        )
    end, true)
end

-- Moves the clone in `dir` to `target`: what it names is fetched, then the checkout goes there.
local function move_to(dir, target, report, cb)
    if target.commit then return fetch_commit(dir, target.commit, cb) end
    local fetch = remote_git({ 'fetch', '--depth', '1', '--progress', 'origin', target.ref }, dir)
    run_cmd(fetch, remote_opts(), report, function(fetched, err)
        vim.schedule(function()
            if not fetched then return cb(false, err) end
            git(dir, { 'reset', '--hard', 'FETCH_HEAD^{commit}' }, cb)
        end)
    end)
end

-- The branch or tag to clone for a pin, which `git clone --branch` takes for either.
local function clone_ref(pin)
    if pin and (pin.kind == 'branch' or pin.kind == 'tag' or pin.kind == 'ref') then return pin.value end
end

-- Clones the plugin at the commit the lock file names while the spec still asks for the pin that commit came
-- from. Otherwise at what the spec's pin asks for: a branch or tag is cloned itself, a version is the highest
-- tag in its range, a commit is fetched after the clone, and no pin is the default branch.
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
    local url, wanted = clone_url(spec.repo), spec.pin
    local key = wanted and pins.key(wanted)
    local function fail(err)
        vim.fn.delete(staging, 'rf')
        done(false, err)
    end
    local function move()
        local moved, move_err = uv.fs_rename(staging, dest)
        if not moved then return fail('atomic move failed: ' .. tostring(move_err)) end
        make_helptags(dest)
        lock.mark(job.plugin, dest, key)
        done(true)
    end
    -- `commit`, when given, is checked out after the clone; `label` says where it came from.
    local function clone(branch, commit, label)
        local args = { 'clone', '--depth', '1', '--progress' }
        if branch then vim.list_extend(args, { '--branch', branch }) end
        run_cmd(remote_git(vim.list_extend(args, { url, staging })), remote_opts(), report, function(ok, err)
            vim.schedule(function()
                if not ok then return fail(err) end
                if not commit then return move() end
                git(staging, { 'rev-parse', 'HEAD' }, function(read, head)
                    if read and is_commit(head, commit) then return move() end
                    fetch_commit(staging, commit, function(fetched, why)
                        if not fetched then
                            return fail(
                                string.format('%s %s is not available: %s', label, short(commit), why)
                            )
                        end
                        move()
                    end)
                end)
            end)
        end)
    end
    local locked = lock.get(job.plugin, key)
    if locked then return clone(clone_ref(wanted), locked, 'locked commit') end
    if wanted and wanted.kind == 'commit' then return clone(nil, wanted.value, 'commit') end
    if wanted and wanted.kind == 'version' then
        return find_target(vim.fn.fnamemodify(staging, ':h'), url, wanted, function(found, target)
            if not found then return fail(target) end
            clone(target.tag)
        end)
    end
    clone(clone_ref(wanted))
end

-- `check` or `update` of a plugin: asks its remote where the plugin should be (see find_target), compares that
-- with `HEAD`, and for `update` (`spec.apply`) moves there. Its note says what happened. A plugin with changes of
-- its own is left as it is.
function M.git_update(job, done, report)
    local spec = job.spec
    local dir = paths.install(job.plugin)
    if not uv.fs_stat(dir) then return done(true, 'not installed') end
    job.working = true
    report()
    local wanted = spec.pin
    find_target(dir, 'origin', wanted, function(found, target)
        if not found then return done(false, target) end
        git(dir, { 'rev-parse', 'HEAD' }, function(read, head)
            if not read then return done(false, head) end
            if spec.apply then lock.mark(job.plugin, dir, wanted and pins.key(wanted)) end
            local goal = target.sha or target.commit
            if is_commit(head, goal) then return done(true, 'up to date') end
            local change = short(head) .. ' → ' .. short(goal)
            if not spec.apply then return done(true, 'update available ' .. change) end
            git(dir, { 'status', '--porcelain', '--untracked-files=no' }, function(_, changes)
                if changes ~= '' then return done(true, 'skipped: local changes') end
                move_to(dir, target, report, function(moved, why)
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

-- A conventional commit that says it breaks something: `feat!:` or `feat(scope)!:` in the subject, or a
-- `BREAKING CHANGE` footer.
local function breaking(subject, body)
    return subject:match('^[%w_-]+!:') ~= nil
        or subject:match('^[%w_-]+%b()!:') ~= nil
        or body:match('BREAKING[ -]CHANGE') ~= nil
end

-- The commits after `HEAD` up to what was fetched last, newest first, as { sha, subject, breaking }.
local function commits_ahead(dir, cb)
    git(dir, { 'log', '--format=%H%x1f%s%x1f%b%x1e', 'HEAD..FETCH_HEAD' }, function(ok, out)
        if not ok then return cb(nil) end
        local list = {}
        for record in out:gmatch('[^\30]+') do
            local sha, subject, body = record:match('^%s*(%x+)\31([^\31]*)\31(.*)$')
            if sha then
                table.insert(list, { sha = sha, subject = subject, breaking = breaking(subject, body) })
            end
        end
        cb(list)
    end)
end

--- Whether the plugin in `dir` is where `pin` asks for (see find_target), without moving it: cb(nil) when it is,
--- cb(info) when it is not, and cb(false, why) when the remote could not say. `info` has `from` and `to`, the
--- commits it is at and should be at, and `commits`, the commits in between, newest first, as
--- { sha, subject, breaking }. Only the commits after the one the plugin is at are fetched, and only for a
--- plugin that is behind; `commits` is nil when they could not be, and for a commit pin.
function M.look_ahead(dir, pin, cb)
    find_target(dir, 'origin', pin, function(found, target)
        if not found then return cb(false, target) end
        git(dir, { 'log', '-1', '--format=%H %ct' }, function(read, out)
            local head, time = out:match('^(%x+) (%d+)')
            if not read or not head then return cb(false, read and 'no commit' or out) end
            local goal = target.sha or target.commit
            if is_commit(head, goal) then return cb(nil) end
            local info = { from = head, to = goal }
            if target.commit then return cb(info) end
            -- A day before the plugin's commit, so that commit and everything after it come down.
            local since = os.date('!%Y-%m-%dT%H:%M:%SZ', tonumber(time) - 86400)
            git(dir, { 'fetch', '--shallow-since=' .. since, 'origin', target.ref }, function(fetched)
                if not fetched then return cb(info) end
                commits_ahead(dir, function(list)
                    info.commits = list
                    cb(info)
                end)
            end, true)
        end)
    end)
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

-- Whether the plugin's build has not run at its current commit, checked at once. A plugin with no readable
-- HEAD counts as up to date, since a build would have no commit to record either.
function M.build_stale(name)
    local res = vim.system({ 'git', '-C', paths.install(name), 'rev-parse', 'HEAD' }, { text = true }):wait()
    if res.code ~= 0 then return false end
    return read_record(paths.install(name) .. '/.git/sarcina-build') ~= vim.trim(res.stdout)
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
