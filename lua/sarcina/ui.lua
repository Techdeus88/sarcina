-- sarcina/ui.lua
-- Event bus and the floating window for Sarcina.
-- The window is a pure view of the stats (see window.lua): a header, a list of plugins and, when there is
-- room, a pane with the details of the selected one, and a footer. The list and the details scroll; the
-- header and the footer have windows of their own so they stay in view. This module decides when it opens
-- and which plugins to redraw, owns the four windows, and keeps no task state of its own.
-- Events: "info" | "warn" | "warning" | "error" (strings, shown in the right of the header; never as a
-- notification or in the command line), "debug" (string, listeners only),
-- "task" (job), "start", "done" (summary), "updates" (the state of checker.lua).

local M = {}

-- When the window opens by itself: 'auto' on real work and on a failure, 'always' at every startup, 'never'.
M.show = 'auto'
-- Whether opening the window looks for updates (see checker.lua). Off, `C` in the window or :Sarcina check does it.
M.check_on_open = true
-- The black layer behind a window opened by hand: its winblend, 0 solid black to 100 invisible. false: none.
local DEFAULT_BACKDROP = 50
M.backdrop = DEFAULT_BACKDROP

M._listeners = {}
M._messages = {} -- every message of the session, as { msg, level }, for tests and for ui.messages()
M._question = nil -- { prompt, callback } while the header waits for y or n
M.message_ttl = 8000 -- how long a message stays in the header, ms; an error stays three times as long
M._bufnr = nil -- the list
M._winid = nil
M._detail_bufnr = nil
M._detail_winid = nil
M._header_bufnr = nil
M._header_winid = nil
M._footer_bufnr = nil
M._footer_winid = nil
M._backdrop_winid = nil
M._dismissed = false
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

--- `count` and `word`, plural unless it is one: `1 plugin`, `4 plugins`.
function M.plural(count, word) return count .. ' ' .. word .. (count == 1 and '' or 's') end

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
    -- Only window.lua writes to it, and only for the length of a draw.
    vim.bo[buf].modifiable = false
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
    local height = opts and opts.height or 'regular'
    if not window().is_height(height) then
        M.emit('warning', string.format('Unknown ui.height %s, using regular', tostring(height)))
        height = 'regular'
    end
    window().height = height
    M.check_on_open = not opts or opts.check_on_open ~= false
    local backdrop = opts and opts.backdrop
    if backdrop == nil then backdrop = DEFAULT_BACKDROP end
    if backdrop ~= false and not (type(backdrop) == 'number' and backdrop >= 0 and backdrop <= 100) then
        M.emit(
            'warning',
            string.format('Unknown ui.backdrop %s, using %d', tostring(backdrop), DEFAULT_BACKDROP)
        )
        backdrop = DEFAULT_BACKDROP
    end
    M.backdrop = backdrop
end

-- The keys the footer names. `=` and `-` say which view and which height they switch to.
-- The keys, for the footer, in the order they are dropped from the end when the footer is too narrow for all.
local function hint()
    local keys
    if M._question then return ' y yes · n no ' end
    if window().select_mode then
        keys = { 'v done', '␣ pick', 'c u i l d act on picks', 'q close', '^d/^u scroll' }
    else
        keys = {
            'q close',
            '= ' .. (window().view == 'main' and '50/50' or '70/30'),
            '- ' .. (window().height == 'regular' and 'taller' or 'shorter'),
            'v select',
            '⏎ changelog',
            'c/C check',
            'u/U update',
            'i install',
            'l load',
            'd delete',
            '^d/^u scroll',
        }
    end
    local width = window().config().footer.width
    local text = ' ' .. table.concat(keys, ' · ') .. ' '
    while #keys > 1 and vim.fn.strdisplaywidth(text) > width - 4 do
        table.remove(keys)
        text = ' ' .. table.concat(keys, ' · ') .. ' '
    end
    return text
end

-- Draws the details of the selected plugin. A different plugin starts at the top of the window.
local function show_details()
    if not pane_valid('detail') then return end
    local win = pane_win('detail')
    local name = window().draw_details(pane_buf('detail'))
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
        -- The cursor goes back to the row of the plugin it was on, which may have moved.
        local at = window().entry_at(vim.api.nvim_win_get_cursor(M._winid)[1])
        local line = window().line(before)
        if line and not (at and at.name == before) then vim.api.nvim_win_set_cursor(M._winid, { line, 0 }) end
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

local function backdrop_valid() return M._backdrop_winid and vim.api.nvim_win_is_valid(M._backdrop_winid) end

-- The whole editor, for the backdrop.
local function backdrop_config()
    return { relative = 'editor', row = 0, col = 0, width = vim.o.columns, height = vim.o.lines }
end

-- A float over the whole editor, under the windows (zindex 50), so nothing behind them shows through.
local function open_backdrop()
    if M.backdrop == false or backdrop_valid() then return end
    vim.api.nvim_set_hl(0, 'SarcinaBackdrop', { bg = '#000000', default = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    M._backdrop_winid = vim.api.nvim_open_win(
        buf,
        false,
        vim.tbl_extend(
            'force',
            backdrop_config(),
            { style = 'minimal', focusable = false, zindex = 45, noautocmd = true }
        )
    )
    vim.wo[M._backdrop_winid].winhighlight = 'Normal:SarcinaBackdrop,EndOfBuffer:SarcinaBackdrop'
    vim.wo[M._backdrop_winid].winblend = M.backdrop
end

local function close_backdrop()
    if backdrop_valid() then pcall(vim.api.nvim_win_close, M._backdrop_winid, true) end
    M._backdrop_winid = nil
end

local function close_panes()
    for _, name in ipairs(PANES) do
        close_pane(name)
    end
    close_backdrop()
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
    if backdrop_valid() then vim.api.nvim_win_set_config(M._backdrop_winid, backdrop_config()) end
    vim.api.nvim_win_set_config(M._winid, config.list)
    for _, name in ipairs({ 'header', 'footer' }) do
        if pane_valid(name) then vim.api.nvim_win_set_config(pane_win(name), config[name]) end
    end
    if pane_valid('footer') then
        vim.api.nvim_win_set_config(pane_win('footer'), { footer = hint(), footer_pos = 'center' })
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
        vim.api.nvim_win_set_config(pane_win('footer'), { footer = hint(), footer_pos = 'center' })
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
    if not (entry and entry.name) then return end
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

-- The list moves up and down and nowhere else: no key takes the cursor sideways or scrolls the view sideways, and
-- no key that edits can reach the buffer or put an error in the command line.
local SIDEWAYS = {
    'h',
    '<Left>',
    '<Right>',
    '0',
    '^',
    '$',
    '<Home>',
    '<End>',
    'w',
    'W',
    'b',
    'B',
    'e',
    'E',
    'ge',
    'gE',
    ';',
    ',',
    '|',
    'zh',
    'zl',
    'zH',
    'zL',
    'zs',
    'ze',
    '<S-Left>',
    '<S-Right>',
    '<C-Left>',
    '<C-Right>',
    'g0',
    'g^',
    'g$',
    'gm',
    'gM',
    '<ScrollWheelLeft>',
    '<ScrollWheelRight>',
}
-- These wait for a character, which has to go too or it would run as a key of its own.
local SIDEWAYS_WITH_CHAR = { 'f', 'F', 't', 'T' }
local EDITING =
    { 'a', 'A', 'o', 'O', 'I', 'x', 'X', 'p', 'P', 's', 'S', 'r', 'R', 'J', 'gJ', '~', '.', '<C-r>', 'D' }

local function lock_list(buf)
    local function map(modes, key, rhs)
        vim.keymap.set(modes, key, rhs, { buffer = buf, nowait = true, silent = true })
    end
    for _, key in ipairs(SIDEWAYS) do
        map({ 'n', 'x' }, key, '<Nop>')
    end
    for _, key in ipairs(SIDEWAYS_WITH_CHAR) do
        map({ 'n', 'x' }, key, function() vim.fn.getcharstr() end)
    end
    for _, key in ipairs(EDITING) do
        map('n', key, '<Nop>')
    end
end

-- On the first row the cursor can rest on, the blank line above it stays in view. On the last row, the blank
-- line below it. Vim scrolls only as far as the cursor, which hid them.
local function show_ends(lnum)
    local first, last = window().ends()
    local view = vim.api.nvim_win_call(M._winid, vim.fn.winsaveview)
    local top
    if lnum == first and view.topline > 1 then
        top = 1
    elseif lnum == last then
        local bottom = vim.api.nvim_buf_line_count(M._bufnr) - vim.api.nvim_win_get_height(M._winid) + 1
        if view.topline < bottom then top = bottom end
    end
    if top then vim.api.nvim_win_call(M._winid, function() vim.fn.winrestview({ topline = top }) end) end
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
    vim.keymap.set(
        'n',
        '-',
        function() M.toggle_height() end,
        { buffer = M._bufnr, nowait = true, desc = 'Switch the Sarcina window between 80% and 95% tall' }
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
    lock_list(M._bufnr)
    for key, yes in pairs({ y = true, n = false, ['<Esc>'] = false }) do
        vim.keymap.set('n', key, function()
            if M._question then M._answer(yes) end
        end, { buffer = M._bufnr, nowait = true, desc = 'Answer the question in the Sarcina header' })
    end
    vim.keymap.set(
        'n',
        'v',
        M.toggle_select,
        { buffer = M._bufnr, nowait = true, desc = 'Toggle the select view' }
    )
    vim.keymap.set(
        'n',
        '<Space>',
        M.toggle_pick,
        { buffer = M._bufnr, nowait = true, desc = 'Pick a plugin' }
    )
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
            -- The cursor rests only on rows of plugins: off a header or a blank line it goes on the way it moved.
            local pos = vim.api.nvim_win_get_cursor(M._winid)
            local lnum = pos[1]
            -- A click can land the cursor in a column; the list only has rows.
            if pos[2] ~= 0 then vim.api.nvim_win_set_cursor(M._winid, { lnum, 0 }) end
            local entry = window().entry_at(lnum)
            if not (entry and entry.name) then
                local to = window().nearest(lnum, lnum < (M._last_lnum or 1) and -1 or 1)
                if to then
                    vim.api.nvim_win_set_cursor(M._winid, { to, 0 })
                    lnum = to
                end
            end
            M._last_lnum = lnum
            show_ends(lnum)
            window().select(lnum)
            show_details()
        end,
    })
end

local function open_window(enter)
    ensure_buffer()
    M._header_bufnr, M._footer_bufnr = new_buffer(), new_buffer()
    window().draw(buffers())
    local config = window().config()
    -- Only a window you open: one that opens by itself during a run must not black out what you are typing in.
    if enter then open_backdrop() end
    M._winid = vim.api.nvim_open_win(
        M._bufnr,
        enter,
        vim.tbl_extend('force', config.list, { style = 'minimal', border = 'rounded', noautocmd = true })
    )
    vim.wo[M._winid].wrap = false
    vim.wo[M._winid].cursorline = true
    open_pane('header', config.header)
    open_pane('footer', config.footer, { footer = hint(), footer_pos = 'center' })
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
            close_panes()
            window().closed()
            if M._question then vim.schedule(function() M._answer(false) end) end
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
    -- A plugin an update moved, or found where it should be, has no update left to show.
    local checker = package.loaded['sarcina.checker']
    if checker and job.id == 'update' and job.status == 'done' then
        local note = job.note or ''
        if note == 'up to date' or note:find('→', 1, true) then checker.settled(job.plugin) end
    end
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
    local text = M.plural(summary.done, 'task') .. ' done'
    if summary.failed > 0 then text = text .. string.format(', %d failed', summary.failed) end
    if summary.skipped > 0 then text = text .. string.format(', %d skipped', summary.skipped) end
    if summary.failed > 0 then
        M.emit('error', text)
    elseif not summary.quiet then
        -- The count of a clean run is shown if the window is open, and does not open it.
        M._on_message(vim.log.levels.INFO, text, true)
        for _, fn in ipairs(M._listeners) do
            pcall(fn, 'info', text)
        end
    end
end

-- A message for the right of the header: it is kept, shown until the next one or until it times out, and it opens
-- the window like real work does. With `show = 'never'` it is only kept (see `messages`).
function M._on_message(level, text, passive)
    local message = { level = level, text = text }
    require('sarcina.log').write(level, text)
    table.insert(M._messages, { msg = text, level = level })
    window().message = message
    M._want = M._want or not passive
    schedule_flush()
    local ttl = M.message_ttl * (level == vim.log.levels.ERROR and 3 or 1)
    vim.defer_fn(function()
        if window().message ~= message then return end
        window().message = nil
        schedule_flush()
    end, ttl)
end

--- Every message of the session in order, as `{ msg, level }`.
function M.messages() return M._messages end

--- Asks a yes or no in the header and calls `callback(true | false)` once: `y` is yes, `n`, `<Esc>` or closing the
--- window is no. The window opens and takes focus for it, whatever `show` says. Asking while a question is open
--- answers that one with no first.
function M.ask(prompt, callback)
    if M._question then M._answer(false) end
    M._question = { prompt = prompt, callback = callback }
    window().question = { prompt = prompt }
    M._dismissed = false
    if win_valid() then
        window().draw(buffers())
        vim.api.nvim_set_current_win(M._winid)
        follow(false, true)
    else
        open_window(true)
    end
end

function M._answer(yes)
    local question = M._question
    if not question then return end
    M._question, window().question = nil, nil
    if win_valid() then
        window().draw(buffers())
        follow(false, true)
    end
    question.callback(yes)
end

-- Emit an event. `payload` is a string for info/warn/error/debug, a job for "task", a summary for "done".
function M.emit(event, payload)
    local level = LEVELS[event]
    if level then
        M._on_message(level, tostring(payload))
    elseif event == 'task' then
        M._on_task(payload)
    elseif event == 'start' then
        M._on_start(payload)
    elseif event == 'done' then
        M._on_done(payload)
    elseif event == 'updates' or event == 'removed' then
        M._full = true
        schedule_flush()
    end
    if event == 'debug' then require('sarcina.log').write(vim.log.levels.DEBUG, tostring(payload)) end
    for _, fn in ipairs(M._listeners) do
        pcall(fn, event, payload)
    end
end

function M.on(event, callback)
    table.insert(M._listeners, function(ev, payload)
        if ev == event then callback(payload) end
    end)
end

--- Open the window and go into it.
function M.open()
    if #require('sarcina.stats').plugins() == 0 then return M.emit('info', 'No task activity yet') end
    M._dismissed = false
    if win_valid() then
        open_backdrop()
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
end

function M.dismiss()
    M._dismissed = true
    M._seen_failed = snapshot().counts.failed
    M.close()
end

--- Looks for updates in the background (see checker.lua); the details of a plugin show its update.
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
        vim.api.nvim_win_set_config(pane_win('footer'), { footer = hint(), footer_pos = 'center' })
    end
    follow(false, true)
end

--- Switches the window between its heights, regular (80% of the editor) and extended (95%, the extra rows for
--- the list and the details), and redraws it when it is open. The height stays for the rest of the session.
function M.toggle_height()
    window().toggle_height()
    if not win_valid() then return end
    window().draw(buffers())
    apply_config()
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
    vim.api.nvim_create_autocmd('ColorScheme', {
        group = group,
        callback = function()
            window().define_highlights()
            -- The window opened before the colorscheme was here, so it takes the theme's colours now.
            M._full = true
            schedule_flush()
        end,
    })
end

return M
