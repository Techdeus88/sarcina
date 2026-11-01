-- sarcina/ui.lua
-- Event bus and the floating window for Sarcina.
-- The window is a pure view of the stats (see window.lua): a list of plugins and, when there is room, a
-- pane with the details of the selected one. This module decides when it opens and which plugins to
-- redraw, owns the two windows, and keeps no task state of its own.
-- Events: "info" | "warn" | "warning" | "error" (strings, shown as toasts), "debug" (string, listeners only),
-- "task" (job), "start", "done" (summary).

local M = {}

M.close_delay = 3000
-- When the window opens by itself: 'auto' on real work and on a failure, 'always' at every startup, 'never'.
M.show = 'auto'

M._listeners = {}
M._bufnr = nil -- the list
M._winid = nil
M._detail_bufnr = nil
M._detail_winid = nil
M._dismissed = false
M._pinned = false -- opened by hand, so a clean run does not close it
M._seen_failed = 0
M._closing = false
M._dirty = {} -- plugin names with an event since the last flush
M._want = false -- an event since the last flush asked for the window
M._full = false -- the next flush redraws every line
M._flush_pending = false

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

local function detail_valid() return M._detail_winid ~= nil and vim.api.nvim_win_is_valid(M._detail_winid) end

--- Read the `ui` options of setup().
function M.configure(opts)
    local show = opts and opts.show or 'auto'
    if not SHOW[show] then
        M.emit('warning', string.format('Unknown ui.show %s, using auto', tostring(show)))
        show = 'auto'
    end
    M.show = show
end

-- Draws the details of the selected plugin and names the details window after it.
local function show_details()
    if not detail_valid() then return end
    local name = window().draw_details(M._detail_bufnr)
    vim.api.nvim_win_set_config(M._detail_winid, { title = ' ' .. (name or '') .. ' ', title_pos = 'left' })
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

local function close_details()
    if detail_valid() then pcall(vim.api.nvim_win_close, M._detail_winid, true) end
    if M._detail_bufnr and vim.api.nvim_buf_is_valid(M._detail_bufnr) then
        pcall(vim.api.nvim_buf_delete, M._detail_bufnr, { force = true })
    end
    M._detail_bufnr, M._detail_winid = nil, nil
end

local function open_details(config)
    M._detail_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M._detail_bufnr].bufhidden = 'wipe'
    vim.bo[M._detail_bufnr].filetype = 'sarcina'
    local opts = vim.tbl_extend('force', config, {
        style = 'minimal',
        border = 'rounded',
        focusable = false,
        noautocmd = true,
    })
    M._detail_winid = vim.api.nvim_open_win(M._detail_bufnr, false, opts)
    local wo = vim.wo[M._detail_winid]
    wo.wrap, wo.linebreak, wo.breakindent, wo.breakindentopt = true, true, true, 'shift:10'
end

-- Puts both windows where the last full draw says: the details one comes and goes with the room for it.
local function apply_config()
    local config = window().config()
    vim.api.nvim_win_set_config(M._winid, config.list)
    if not config.detail then return close_details() end
    if detail_valid() then
        vim.api.nvim_win_set_config(M._detail_winid, config.detail)
    else
        open_details(config.detail)
    end
end

local function ensure_buffer()
    if buf_valid() then return end
    window().define_highlights()
    M._bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M._bufnr].bufhidden = 'wipe'
    vim.bo[M._bufnr].filetype = 'sarcina'
    vim.keymap.set('n', 'q', M.dismiss, { buffer = M._bufnr, nowait = true, desc = 'Close Sarcina window' })
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
    window().draw(M._bufnr)
    local config = window().config()
    local opts = vim.tbl_extend('force', config.list, {
        style = 'minimal',
        border = 'rounded',
        footer = ' q close ',
        footer_pos = 'right',
        noautocmd = true,
    })
    M._winid = vim.api.nvim_open_win(M._bufnr, enter, opts)
    vim.wo[M._winid].wrap = false
    vim.wo[M._winid].cursorline = true
    if config.detail then open_details(config.detail) end
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
            close_details()
            window().closed()
        end,
    })
    M._seen_failed = snapshot().counts.failed
    follow(true)
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
        window().draw(M._bufnr)
    else
        redrawn = window().refresh(M._bufnr, dirty)
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
        window().draw(M._bufnr)
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
    close_details()
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
