-- sarcina/ui.lua
-- Event bus and floating task panel for Sarcina.
-- The panel is a pure view: it renders `tasks.snapshot()` and keeps no task state of its own.
-- Events: "info" | "warn" | "warning" | "error" (strings, shown as toasts), "debug" (string, listeners only),
-- "task" (job), "start", "done" (summary).

local M = {}

M.show_delay = 250
M.close_delay = 3000

M._listeners = {}
M._bufnr = nil
M._winid = nil
M._dismissed = false
M._seen_failed = 0
M._closing = false
M._render_pending = false
M._delay_passed = true
M._run_id = 0

local NS = vim.api.nvim_create_namespace('sarcina_ui')

local GLYPH = { pending = '…', running = '▶', done = '✔', failed = '✘', skipped = '⊘' }
local HL = {
    pending = 'SarcinaPending',
    running = 'SarcinaRunning',
    done = 'SarcinaDone',
    failed = 'SarcinaFailed',
    skipped = 'SarcinaSkipped',
}
local HL_LINKS = {
    SarcinaPending = 'Comment',
    SarcinaRunning = 'DiagnosticInfo',
    SarcinaDone = 'DiagnosticOk',
    SarcinaFailed = 'DiagnosticError',
    SarcinaSkipped = 'Comment',
    SarcinaNote = 'Comment',
}
local LEVELS = {
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    warning = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
}

local function snapshot() return require('sarcina.tasks').snapshot() end

local function buf_valid() return M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) end

local function win_valid() return M._winid ~= nil and vim.api.nvim_win_is_valid(M._winid) end

local function define_highlights()
    for name, link in pairs(HL_LINKS) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
end

function M._schedule_render()
    if M._render_pending then return end
    M._render_pending = true
    vim.schedule(function()
        M._render_pending = false
        M._render()
    end)
end

-- A fresh run starts over: the panel may open again and earlier failures count as unseen.
function M._on_start(info)
    if info == nil or info.fresh then
        M._dismissed = false
        M._seen_failed = 0
    end
    M._run_id = M._run_id + 1
    local run = M._run_id
    M._delay_passed = M.show_delay <= 0
    vim.defer_fn(function()
        if run == M._run_id then
            M._delay_passed = true
            M._schedule_render()
        end
    end, M.show_delay)
end

function M._on_done(summary)
    if summary.total == 0 then return end
    local text = string.format('%d done', summary.done)
    if summary.failed > 0 then text = text .. string.format(', %d failed', summary.failed) end
    if summary.skipped > 0 then text = text .. string.format(', %d skipped', summary.skipped) end
    if summary.failed > 0 or not summary.quiet then M.emit(summary.failed > 0 and 'error' or 'info', text) end
    -- Failures from earlier in the session keep the panel open, whichever run this was.
    if snapshot().counts.failed == 0 then
        vim.defer_fn(function()
            if not require('sarcina.tasks').has_active() then M.close() end
        end, M.close_delay)
    end
end

-- Emit an event. `payload` is a string for info/warn/error/debug, a job for "task", a summary for "done".
function M.emit(event, payload)
    local level = LEVELS[event]
    if level then
        vim.notify('[Sarcina] ' .. tostring(payload), level)
    elseif event == 'task' then
        M._schedule_render()
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

local function describe(job)
    if job.status == 'failed' then return 'error: ' .. (tostring(job.error):match('[^\n]+') or 'unknown') end
    local bits = {}
    local function add(text)
        if text then table.insert(bits, text) end
    end
    if job.status == 'running' then
        add(job.attempts > 1 and 'try ' .. job.attempts or nil)
        add(job.output)
    elseif job.status == 'skipped' then
        add(job.note)
    elseif job.status == 'done' then
        add(job.note)
        add(job.duration and job.duration >= 100 and string.format('%.1fs', job.duration / 1000) or nil)
    end
    return table.concat(bits, ' · ')
end

local function panel_width() return math.min(math.max(40, math.floor(vim.o.columns * 0.4)), vim.o.columns - 4) end

local function fit(text, max)
    if max < 4 then return '' end
    if vim.fn.strdisplaywidth(text) <= max then return text end
    return vim.fn.strcharpart(text, 0, max - 1) .. '…'
end

-- A running row's output changes constantly, so it is cut to one line to keep the window height steady.
local function build_rows(jobs, width)
    local rows = {}
    for i, job in ipairs(jobs) do
        local head = string.format('%s %s – %s', GLYPH[job.status], job.plugin, job.id)
        local note = describe(job)
        if job.status == 'running' then note = fit(note, width - vim.fn.strdisplaywidth(head) - 2) end
        rows[i] = {
            line = note ~= '' and (head .. '  ' .. note) or head,
            glyph_len = #GLYPH[job.status],
            note_col = note ~= '' and (#head + 2) or nil,
            status = job.status,
        }
    end
    return rows
end

local function title(snap)
    local c = snap.counts
    local text = string.format(' Sarcina %d/%d', c.done + c.failed + c.skipped, snap.total)
    if c.failed > 0 then text = text .. string.format(' · %d failed', c.failed) end
    return text .. ' '
end

local function layout(lines, width)
    local height = 0
    for _, line in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
    local max_height = math.max(5, math.floor(vim.o.lines * 0.5))
    return {
        relative = 'editor',
        row = 1,
        col = vim.o.columns - width - 2,
        width = width,
        height = math.min(height, max_height),
    }
end

local function ensure_buffer()
    if buf_valid() then return end
    define_highlights()
    M._bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M._bufnr].bufhidden = 'wipe'
    vim.bo[M._bufnr].filetype = 'sarcina'
    vim.keymap.set('n', 'q', M.dismiss, { buffer = M._bufnr, nowait = true, desc = 'Close Sarcina panel' })
end

local function open_window(config)
    local opts = vim.tbl_extend('force', config, { style = 'minimal', border = 'rounded', noautocmd = true })
    M._winid = vim.api.nvim_open_win(M._bufnr, false, opts)
    vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(M._winid),
        once = true,
        callback = function()
            if not M._closing then
                M._dismissed = true
                M._seen_failed = snapshot().counts.failed
            end
            M._winid = nil
        end,
    })
end

local function draw(rows)
    local lines = vim.tbl_map(function(row) return row.line end, rows)
    vim.bo[M._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, lines)
    vim.bo[M._bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)
    for i, row in ipairs(rows) do
        vim.api.nvim_buf_set_extmark(
            M._bufnr,
            NS,
            i - 1,
            0,
            { end_col = row.glyph_len, hl_group = HL[row.status] }
        )
        if row.note_col then
            local hl = row.status == 'failed' and 'SarcinaFailed' or 'SarcinaNote'
            vim.api.nvim_buf_set_extmark(
                M._bufnr,
                NS,
                i - 1,
                row.note_col,
                { end_col = #row.line, hl_group = hl }
            )
        end
    end
    return lines
end

local function follow(jobs)
    local running, failed
    for i, job in ipairs(jobs) do
        if job.status == 'running' then
            running = i
        elseif job.status == 'failed' then
            failed = i
        end
    end
    vim.api.nvim_win_set_cursor(M._winid, { running or failed or #jobs, 0 })
end

-- A failure the user has not seen yet opens the panel at once; plain progress waits for show_delay.
local function should_open(snap)
    if snap.counts.failed > M._seen_failed then return true end
    if not require('sarcina.tasks').has_active() then return false end
    return M._delay_passed
end

-- Render the current task state. `force` opens the panel regardless of run age.
function M._render(force)
    local snap = snapshot()
    if snap.total == 0 then return end
    if M._dismissed then
        if snap.counts.failed <= M._seen_failed then return end
        M._dismissed = false
    end
    if not win_valid() and not force and not should_open(snap) then return end
    ensure_buffer()
    local width = panel_width()
    local lines = draw(build_rows(snap.jobs, width))
    local config = layout(lines, width)
    config.title = title(snap)
    config.title_pos = 'center'
    if win_valid() then
        vim.api.nvim_win_set_config(M._winid, config)
    else
        open_window(config)
    end
    M._seen_failed = snap.counts.failed
    follow(snap.jobs)
end

function M.open()
    if snapshot().total == 0 then return M.emit('info', 'No task activity yet') end
    M._dismissed = false
    M._render(true)
end

function M.close()
    M._closing = true
    if win_valid() then pcall(vim.api.nvim_win_close, M._winid, true) end
    if buf_valid() then pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true }) end
    M._closing = false
    M._bufnr, M._winid = nil, nil
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
    define_highlights()
    local group = vim.api.nvim_create_augroup('SarcinaUI', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = group,
        callback = function() M.close() end,
    })
    vim.api.nvim_create_autocmd('VimResized', {
        group = group,
        callback = function() M._schedule_render() end,
    })
    vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = define_highlights })
end

return M
