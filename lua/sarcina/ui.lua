-- sarcina/ui.lua
-- Event bus and the floating window for Sarcina.
-- The window is a pure view of the stats (see window.lua): a header, a list of plugins and, when there is
-- room, a pane with the details of the selected one, and a footer. The list and the details scroll; the
-- header and the footer have windows of their own so they stay in view. This module decides when it opens
-- and which plugins to redraw, owns the four windows, and keeps no task state of its own.
-- Events: "info" | "warn" | "warning" | "error" (strings, shown as toasts), "debug" (string, listeners only),
-- "task" (job), "start", "done" (summary), "updates" (the state of checker.lua).

local M = {}

M.close_delay = 3000
-- When the window opens by itself: 'auto' on real work and on a failure, 'always' at every startup, 'never'.
M.show = 'auto'
-- Whether opening the window looks for updates (see checker.lua). Off, `C` in the window or :Sarcina check does it.
M.check_on_open = true

M._listeners = {}
M._bufnr = nil -- the list
M._winid = nil
M._detail_bufnr = nil
M._detail_winid = nil
M._header_bufnr = nil
M._header_winid = nil
M._footer_bufnr = nil
M._footer_winid = nil
M._dismissed = false
M._pinned = false -- opened by hand, so a clean run does not close it
M._seen_failed = 0
M._closing = false
M._dirty = {} -- plugin names with an event since the last flush
M._want = false -- an event since the last flush asked for the window
M._full = false -- the next flush redraws every line
M._flush_pending = false
M._check_after_run = false -- the window opened during a run, so it checks for updates when the run ends

local SHOW = { auto = true, always = true, never = true }
local LEVELS = {
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    warning = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
}

local function snapshot() return require('sarcina.tasks').snapshot() end

local function window() return require('sarcina.window') end

local function buf_valid() return M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) end

local function win_valid() return M._winid ~= nil and vim.api.nvim_win_is_valid(M._winid) end

-- The windows besides the list are `header`, `detail` and `footer`, each with its buffer and window in
-- `ui._<name>_bufnr` and `ui._<name>_winid`.
local PANES = { 'header', 'detail', 'footer' }
local shown -- the plugin the details window showed last

local function pane_win(name) return M['_' .. name .. '_winid'] end

local function pane_buf(name) return M['_' .. name .. '_bufnr'] end

local function pane_valid(name)
    local win = pane_win(name)
    return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function new_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'sarcina'
    return buf
end

-- The three buffers window.lua draws into.
local function buffers() return { list = M._bufnr, header = M._header_bufnr, footer = M._footer_bufnr } end

--- Read the `ui` options of setup().
function M.configure(opts)
    local show = opts and opts.show or 'auto'
    if not SHOW[show] then
        M.emit('warning', string.format('Unknown ui.show %s, using auto', tostring(show)))
        show = 'auto'
    end
    M.show = show
    window().rounded = not opts or opts.rounded ~= false
    local view = opts and opts.view or 'main'
    if not window().is_view(view) then
        M.emit('warning', string.format('Unknown ui.view %s, using main', tostring(view)))
        view = 'main'
    end
    window().view = view
    M.check_on_open = not opts or opts.check_on_open ~= false
end

-- The keys the footer names. `=` says which view it switches to.
local function hint()
    local other = window().view == 'main' and '50/50' or '70/30'
    if window().select_mode then return ' v done · Space pick · c u i l d act on picks · ^d ^u scroll ' end
    return ' q close · = ' .. other .. ' · v select · C check · U update · ^d ^u scroll details '
end

-- Draws the details of the selected plugin and names the details window after it. A different plugin
-- starts at the top of the window.
local function show_details()
    if not pane_valid('detail') then return end
    local win = pane_win('detail')
    local name = window().draw_details(pane_buf('detail'))
    vim.api.nvim_win_set_config(win, { title = ' ' .. (name or '') .. ' ', title_pos = 'left' })
    if name ~= shown then
        shown = name
        vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = 1, lnum = 1, leftcol = 0 }) end)
    end
end

-- Puts the cursor on the plugin at work. A user who is in the window keeps their plugin: after the rows
-- moved, the cursor goes back to it. The details are drawn again when the plugin shown changed, or when
-- `dirty` is true or has an event for it.
local function follow(opened, dirty)
    local before = window().selected()
    if not opened and vim.api.nvim_get_current_win() == M._winid then
        local line = window().line(before)
        if line then vim.api.nvim_win_set_cursor(M._winid, { line, 0 }) end
    else
        local line = window().target()
        vim.api.nvim_win_set_cursor(M._winid, { line, 0 })
        window().select(line)
    end
    local now = window().selected()
    if opened or dirty == true or now ~= before or (dirty and dirty[now]) then show_details() end
end

local function close_pane(name)
    if pane_valid(name) then pcall(vim.api.nvim_win_close, pane_win(name), true) end
    local buf = pane_buf(name)
    if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    M['_' .. name .. '_bufnr'], M['_' .. name .. '_winid'] = nil, nil
end

local function close_panes()
    for _, name in ipairs(PANES) do
        close_pane(name)
    end
    shown = nil
end

-- Opens a window that cannot take focus, in the buffer it already has or a new one.
local function open_pane(name, config, extra)
    local buf = pane_buf(name) or new_buffer()
    local opts = vim.tbl_extend(
        'force',
        config,
        { style = 'minimal', border = 'rounded', focusable = false, noautocmd = true },
        extra or {}
    )
    M['_' .. name .. '_bufnr'] = buf
    M['_' .. name .. '_winid'] = vim.api.nvim_open_win(buf, false, opts)
    return pane_win(name)
end

local function open_detail(config)
    local wo = vim.wo[open_pane('detail', config)]
    wo.wrap, wo.linebreak, wo.breakindent, wo.breakindentopt = true, true, true, 'shift:10'
end

-- Puts the windows where the last full draw says: the details one comes and goes with the room for it.
local function apply_config()
    local config = window().config()
    vim.api.nvim_win_set_config(M._winid, config.list)
    for _, name in ipairs({ 'header', 'footer' }) do
        if pane_valid(name) then vim.api.nvim_win_set_config(pane_win(name), config[name]) end
    end
    if not config.detail then return close_pane('detail') end
    if pane_valid('detail') then
        vim.api.nvim_win_set_config(pane_win('detail'), config.detail)
    else
        open_detail(config.detail)
    end
end

-- Scrolls the details by a page of the keys Neovim scrolls with, without leaving the list.
local function scroll_details(key)
    if not pane_valid('detail') then return end
    vim.api.nvim_win_call(
        pane_win('detail'),
        function() vim.cmd.normal({ vim.keycode(key), bang = true }) end
    )
end

-- list-key -> { subcommand, uses the plugins under the cursor or selection (false: every plugin) }
local ACTIONS = {
    c = { 'check', true, 'Check the plugin under the cursor' },
    C = { 'check', false, 'Check every plugin' },
    u = { 'update', true, 'Update the plugin under the cursor' },
    U = { 'update', false, 'Update every plugin' },
    i = { 'install', true, 'Install the plugin under the cursor' },
    l = { 'load', true, 'Load the plugin under the cursor' },
    d = { 'delete', true, 'Delete the plugin under the cursor' },
}

-- The plugins the keys act on: the picks of the select view, else the lines the cursor is on, or a visual
-- selection covers, in list order.
local function plugins_in_selection()
    local picked = window().marked()
    if #picked > 0 then return picked end
    local first, last = vim.fn.line('.'), vim.fn.line('.')
    if vim.fn.mode():match('^[vV\22]') then
        first, last = math.min(first, vim.fn.line('v')), math.max(first, vim.fn.line('v'))
    end
    local names = {}
    for lnum = first, last do
        local entry = window().entry_at(lnum)
        if entry then table.insert(names, entry.name) end
    end
    return names
end

local function refresh_select()
    if not win_valid() then return end
    -- The cursor may have moved since the last CursorMoved ran; the redraw keeps the cursor on the selection.
    window().select(vim.api.nvim_win_get_cursor(M._winid)[1])
    window().draw(buffers())
    if pane_valid('footer') then
        vim.api.nvim_win_set_config(pane_win('footer'), { footer = hint(), footer_pos = 'right' })
    end
    follow(false, true)
end

--- `v`: enters the select view, or leaves it and drops every pick.
function M.toggle_select()
    window().toggle_select_mode()
    refresh_select()
end

--- Leaves the select view, as after an action on the picks.
function M.leave_select()
    if window().select_mode then M.toggle_select() end
end

--- `Space`: picks the plugin under the cursor, or drops it. Only in the select view.
function M.toggle_pick()
    local lnum = vim.api.nvim_win_get_cursor(M._winid)[1]
    local entry = window().entry_at(lnum)
    if not (entry and entry.kind == 'plugin') then return end
    window().select(lnum)
    window().toggle_mark(entry.name)
    refresh_select()
end

local function map_actions(buf)
    for key, action in pairs(ACTIONS) do
        local command, selected, desc = action[1], action[2], action[3]
        local function run()
            local fargs = { command }
            if selected then
                local names = plugins_in_selection()
                vim.cmd('normal! \27')
                if #names == 0 then return end
                vim.list_extend(fargs, names)
            end
            require('sarcina.cli').dispatch({ fargs = fargs, bang = false })
            if selected and window().select_mode then M.leave_select() end
        end
        vim.keymap.set({ 'n', 'x' }, key, run, { buffer = buf, nowait = true, desc = desc })
    end
end

local function ensure_buffer()
    if buf_valid() then return end
    window().define_highlights()
    M._bufnr = new_buffer()
    vim.keymap.set('n', 'q', M.dismiss, { buffer = M._bufnr, nowait = true, desc = 'Close Sarcina window' })
    vim.keymap.set(
        'n',
        '=',
        function() M.toggle_view() end,
        { buffer = M._bufnr, nowait = true, desc = 'Switch the Sarcina view between 70/30 and 50/50' }
    )
    vim.keymap.set('n', '<CR>', function()
        window().toggle_changelog()
        show_details()
    end, {
        buffer = M._bufnr,
        nowait = true,
        desc = 'Show the changelog of a Sarcina update, or its tasks',
    })
    map_actions(M._bufnr)
    vim.keymap.set('n', 'v', M.toggle_select, { buffer = M._bufnr, nowait = true, desc = 'Toggle the select view' })
    vim.keymap.set('n', '<Space>', M.toggle_pick, { buffer = M._bufnr, nowait = true, desc = 'Pick a plugin' })
    for _, key in ipairs({ '<C-d>', '<C-u>' }) do
        vim.keymap.set(
            'n',
            key,
            function() scroll_details(key) end,
            { buffer = M._bufnr, desc = 'Scroll the Sarcina details' }
        )
    end
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M._bufnr,
        callback = function()
            if not win_valid() then return end
            window().select(vim.api.nvim_win_get_cursor(M._winid)[1])
            show_details()
        end,
    })
end

local function open_window(enter)
    ensure_buffer()
    M._header_bufnr, M._footer_bufnr = new_buffer(), new_buffer()
    window().draw(buffers())
    local config = window().config()
    M._winid = vim.api.nvim_open_win(
        M._bufnr,
        enter,
        vim.tbl_extend('force', config.list, { style = 'minimal', border = 'rounded', noautocmd = true })
    )
    vim.wo[M._winid].wrap = false
    vim.wo[M._winid].cursorline = true
    open_pane('header', config.header)
    open_pane('footer', config.footer, { footer = hint(), footer_pos = 'right' })
    if config.detail then open_detail(config.detail) end
    vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(M._winid),
        once = true,
        callback = function()
            if not M._closing then
                M._dismissed = true
                M._seen_failed = snapshot().counts.failed
            end
            M._winid = nil
            M._pinned = false
            close_panes()
            window().closed()
        end,
    })
    M._seen_failed = snapshot().counts.failed
    follow(true)
    if M.check_on_open then M.check(true) end
end

-- Redraws what changed since the last flush, and opens the window when an event asked for it. A failure
-- the user has not seen reopens a dismissed window.
function M._flush()
    M._flush_pending = false
    local dirty, want, full = M._dirty, M._want, M._full
    M._dirty, M._want, M._full = {}, false, false
    local failed = snapshot().counts.failed
    local unseen = failed > M._seen_failed
    if M._dismissed then
        if not unseen then return end
        M._dismissed = false
    end
    if not win_valid() then
        if M.show == 'never' or not (want or unseen) then return end
        return open_window(false)
    end
    local redrawn = full
    if full then
        window().draw(buffers())
    else
        redrawn = window().refresh(buffers(), dirty)
    end
    if redrawn then apply_config() end
    M._seen_failed = failed
    follow(false, redrawn or dirty)
end

local function schedule_flush()
    if M._flush_pending then return end
    M._flush_pending = true
    vim.schedule(M._flush)
end

-- A job changed: its plugin's row needs a redraw, and real work or a failure may open the window.
function M._on_task(job)
    M._dirty[job.plugin] = true
    if job.working or job.status == 'failed' then M._want = true end
    schedule_flush()
end

-- A fresh run starts over: the window may open again and earlier failures count as unseen.
function M._on_start(info)
    local fresh = info == nil or info.fresh
    if fresh then
        M._dismissed = false
        M._seen_failed = 0
        window().forget()
        if M.show == 'always' then M._want = true end
    end
    schedule_flush()
end

function M._on_done(summary)
    schedule_flush()
    if M._check_after_run then
        M._check_after_run = false
        if win_valid() then M.check(true) end
    end
    if summary.total == 0 then return end
    local text = string.format('%d done', summary.done)
    if summary.failed > 0 then text = text .. string.format(', %d failed', summary.failed) end
    if summary.skipped > 0 then text = text .. string.format(', %d skipped', summary.skipped) end
    if summary.failed > 0 or not summary.quiet then M.emit(summary.failed > 0 and 'error' or 'info', text) end
    -- Failures from earlier in the session keep the window open, whichever run this was.
    if snapshot().counts.failed == 0 and not M._pinned then
        vim.defer_fn(function()
            if not M._pinned and not require('sarcina.tasks').has_active() then M.close() end
        end, M.close_delay)
    end
end

-- Emit an event. `payload` is a string for info/warn/error/debug, a job for "task", a summary for "done".
function M.emit(event, payload)
    local level = LEVELS[event]
    if level then
        vim.notify('[Sarcina] ' .. tostring(payload), level)
    elseif event == 'task' then
        M._on_task(payload)
    elseif event == 'start' then
        M._on_start(payload)
    elseif event == 'done' then
        M._on_done(payload)
    elseif event == 'updates' then
        M._full = true
        schedule_flush()
    end
    for _, fn in ipairs(M._listeners) do
        pcall(fn, event, payload)
    end
end

function M.on(event, callback)
    table.insert(M._listeners, function(ev, payload)
        if ev == event then callback(payload) end
    end)
end

--- Open the window and go into it. It stays until you close it.
function M.open()
    if #require('sarcina.stats').plugins() == 0 then return M.emit('info', 'No task activity yet') end
    M._dismissed = false
    M._pinned = true
    if win_valid() then
        window().draw(buffers())
        apply_config()
        vim.api.nvim_set_current_win(M._winid)
        follow(true)
    else
        open_window(true)
    end
end

function M.close()
    M._closing = true
    if win_valid() then pcall(vim.api.nvim_win_close, M._winid, true) end
    if buf_valid() then pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true }) end
    close_panes()
    window().closed()
    M._closing = false
    M._bufnr, M._winid = nil, nil
    M._pinned = false
end

function M.dismiss()
    M._dismissed = true
    M._seen_failed = snapshot().counts.failed
    M.close()
end

--- Looks for updates in the background (see checker.lua); the window shows them in its Updates section.
--- `on_open` is for the check the window starts when it opens: it skips a check that finished a moment ago, and
--- while plugins are being installed or updated it waits for that run to end.
function M.check(on_open)
    local checker = require('sarcina.checker')
    if checker.state().running then return end
    if on_open and checker.fresh() then return end
    if require('sarcina.tasks').has_active() then
        M._check_after_run = true
        return
    end
    checker.run()
end

--- Switches the window between its views, main (the list 70%, the details 30%) and split (50/50), and redraws
--- it when it is open. The view stays for the rest of the session.
function M.toggle_view()
    window().toggle_view()
    if not win_valid() then return end
    window().draw(buffers())
    apply_config()
    if pane_valid('footer') then
        vim.api.nvim_win_set_config(pane_win('footer'), { footer = hint(), footer_pos = 'right' })
    end
    follow(false, true)
end

function M.toggle()
    if win_valid() then
        M.dismiss()
    else
        M.open()
    end
end

function M.init()
    window().define_highlights()
    local group = vim.api.nvim_create_augroup('SarcinaUI', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = group,
        callback = function() M.close() end,
    })
    vim.api.nvim_create_autocmd('VimResized', {
        group = group,
        callback = function()
            M._full = true
            schedule_flush()
        end,
    })
    vim.api.nvim_create_autocmd(
        'User',
        { group = group, pattern = 'SarcinaReady', callback = schedule_flush }
    )
    vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = window().define_highlights })
end

return M
