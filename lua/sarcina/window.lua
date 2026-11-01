-- sarcina/window.lua
-- The floating window: a header, one row per plugin in load order, and a footer, all read from the stats.
-- It keeps no task state, only the rows it last drew, so an event redraws just the lines that changed.
-- ui.lua decides when the window opens and which plugins changed.

local stats = require('sarcina.stats')

local M = {}

local NS = vim.api.nvim_create_namespace('sarcina_window')

local GLYPH = {
    pending = '…',
    installing = '▶',
    building = '▶',
    loading = '▶',
    waiting = '○',
    loaded = '✔',
    blocked = '⊘',
    failed = '✘',
}
local HL = {
    pending = 'SarcinaPending',
    installing = 'SarcinaRunning',
    building = 'SarcinaRunning',
    loading = 'SarcinaRunning',
    waiting = 'SarcinaPending',
    loaded = 'SarcinaDone',
    blocked = 'SarcinaSkipped',
    failed = 'SarcinaFailed',
}
local ACTIVE = { installing = true, building = true, loading = true }
local HL_LINKS = {
    SarcinaPending = 'Comment',
    SarcinaRunning = 'DiagnosticInfo',
    SarcinaDone = 'DiagnosticOk',
    SarcinaFailed = 'DiagnosticError',
    SarcinaSkipped = 'Comment',
    SarcinaNote = 'Comment',
    SarcinaName = 'Normal',
    SarcinaTag = 'Comment',
    SarcinaHeader = 'Title',
    SarcinaFooter = 'Comment',
}

local NAME_MAX, TAG_W, STATE_W, TIME_W, DETAIL_W, SLOWEST = 28, 7, 10, 6, 40, 3

--- Plugin names whose row shows its tasks below it. Nothing sets it yet; a row that expands adds entries
--- of `kind = 'task'` to the map `entry_at` reads.
M.expanded = {}

local entries = {} -- line number -> { kind = 'plugin', name = string }
local line_of = {} -- plugin name -> line number
local rows = {} -- plugin name -> the row as last drawn
local names = {} -- plugin names in line order
-- Fixed at each full draw, so streaming output never resizes the window.
local view = { width = 0, height = 0, detail = 0 }
local columns = { name = 0, progress = 0, prefix = 0 }

function M.define_highlights()
    for name, link in pairs(HL_LINKS) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
end

local function width_of(text) return vim.fn.strdisplaywidth(text) end

local function fit(text, max)
    if max < 1 then return '' end
    if width_of(text) <= max then return text end
    return vim.fn.strcharpart(text, 0, max - 1) .. '…'
end

local function pad(text, width) return text .. string.rep(' ', width - width_of(text)) end

-- Every plugin that ran gets a time. Under 10 ms it keeps a decimal, since most plugins load that fast.
local function format_time(ms)
    if not ms then return '' end
    if ms < 0.1 then return '<0.1ms' end
    if ms < 10 then return string.format('%.1fms', ms) end
    if ms < 1000 then return string.format('%dms', math.floor(ms)) end
    return string.format('%.1fs', ms / 1000)
end

local function progress_text(task, tasks) return string.format('%d of %d tasks', task, tasks) end

--- The one-line numbers of `stats.get()`.
function M.summary(numbers)
    local startup = numbers.startup_ms and string.format('startup %.0f ms', numbers.startup_ms)
        or 'startup pending'
    return string.format(
        '%d plugins · %d loaded · %d not loaded · %d now · %d later · %d triggered · %s',
        numbers.count,
        numbers.loaded,
        numbers.not_loaded,
        numbers.now,
        numbers.later,
        numbers.triggered,
        startup
    )
end

-- A line and its extmarks, `{ start_col, end_col, group }` in bytes, from `{ text, group }` parts.
local function build_line(parts)
    local text, marks, col = {}, {}, 0
    for _, part in ipairs(parts) do
        local piece, group = part[1], part[2]
        if group and #piece > 0 then table.insert(marks, { col, col + #piece, group }) end
        table.insert(text, piece)
        col = col + #piece
    end
    return { text = table.concat(text), marks = marks }
end

local function row_line(row)
    local group = HL[row.state]
    local time = format_time(row.duration)
    local detail = (row.detail or ''):gsub('%s+', ' ')
    return build_line({
        { ' ' },
        { GLYPH[row.state], group },
        { ' ' },
        { pad(fit(row.name, columns.name), columns.name), 'SarcinaName' },
        { ' ' },
        { pad(row.timing or '', TAG_W), 'SarcinaTag' },
        { ' ' },
        { pad(row.state, STATE_W), group },
        { ' ' },
        { pad(progress_text(row.task, row.tasks), columns.progress), 'SarcinaNote' },
        { ' ' },
        { string.rep(' ', TIME_W - width_of(time)) .. time, 'SarcinaNote' },
        { ' ' },
        { fit(detail, view.detail), row.state == 'failed' and 'SarcinaFailed' or 'SarcinaNote' },
    })
end

local function header_line()
    local finished, running, failed = 0, 0, 0
    for _, name in ipairs(names) do
        local state = rows[name].state
        if ACTIVE[state] then running = running + 1 end
        if state == 'failed' then failed = failed + 1 end
        if state ~= 'pending' and not ACTIVE[state] then finished = finished + 1 end
    end
    local text = string.format(' Sarcina · %d of %d plugins', finished, #names)
    if running > 0 then text = text .. string.format(' · %d running', running) end
    if failed > 0 then text = text .. string.format(' · %d failed', failed) end
    return build_line({ { fit(text, view.width), 'SarcinaHeader' } })
end

local function footer_lines()
    local slowest = {}
    for _, name in ipairs(names) do
        if rows[name].duration then table.insert(slowest, rows[name]) end
    end
    table.sort(slowest, function(a, b) return a.duration > b.duration end)
    local parts = {}
    for i = 1, math.min(SLOWEST, #slowest) do
        parts[i] = slowest[i].name .. ' ' .. format_time(slowest[i].duration)
    end
    local slow = ' slowest: ' .. (#parts > 0 and table.concat(parts, ' · ') or '–')
    return {
        build_line({ { fit(' ' .. M.summary(stats.get()), view.width), 'SarcinaFooter' } }),
        build_line({ { fit(slow, view.width), 'SarcinaFooter' } }),
    }
end

-- Fixes the columns and the size from the rows: the fixed columns plus the detail budget, wide enough for
-- the footer, never past 80% of the editor in either direction.
local function measure(list)
    local name_w, progress_w = 0, 0
    for _, row in ipairs(list) do
        name_w = math.max(name_w, width_of(row.name))
        progress_w = math.max(progress_w, width_of(progress_text(row.tasks, row.tasks)))
    end
    columns.name, columns.progress = math.min(name_w, NAME_MAX), progress_w
    columns.prefix = 3 + columns.name + 1 + TAG_W + 1 + STATE_W + 1 + progress_w + 1 + TIME_W + 1
    local n = #list
    local footer = ' '
        .. M.summary({
            count = n,
            loaded = n,
            not_loaded = n,
            now = n,
            later = n,
            triggered = n,
            startup_ms = 99999,
        })
    local max_width = math.max(math.floor(vim.o.columns * 0.8) - 2, 20)
    view.width = math.min(math.max(columns.prefix + DETAIL_W, width_of(footer)), max_width)
    -- Less than a few characters of detail says nothing, so the column goes.
    view.detail = view.width - columns.prefix >= 4 and view.width - columns.prefix or 0
    local max_height = math.max(math.floor((vim.o.lines - vim.o.cmdheight) * 0.8) - 2, 3)
    view.height = math.min(n + 3, max_height)
end

-- Replaces `count` lines from line `first` (1-based) with `lines` and colours them.
local function put(buf, first, count, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        buf,
        first - 1,
        first - 1 + count,
        false,
        vim.tbl_map(function(l) return l.text end, lines)
    )
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS, first - 1, first - 1 + #lines)
    for i, line in ipairs(lines) do
        for _, mark in ipairs(line.marks) do
            vim.api.nvim_buf_set_extmark(
                buf,
                NS,
                first - 2 + i,
                mark[1],
                { end_col = mark[2], hl_group = mark[3] }
            )
        end
    end
end

local function put_ends(buf)
    put(buf, 1, 1, { header_line() })
    put(buf, #names + 2, 2, footer_lines())
end

--- Draws every line from the stats: one row per registered plugin, in the order they loaded. Fixes the
--- width and the height. `list` is `stats.plugins()` when the caller already has it.
function M.draw(buf, list)
    list = list or stats.plugins()
    entries, line_of, rows, names = {}, {}, {}, {}
    measure(list)
    local lines = { build_line({}) }
    for _, row in ipairs(list) do
        table.insert(names, row.name)
        rows[row.name] = row
        line_of[row.name] = #lines + 1
        entries[#lines + 1] = { kind = 'plugin', name = row.name }
        table.insert(lines, row_line(row))
    end
    table.insert(lines, build_line({}))
    table.insert(lines, build_line({}))
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    put(buf, 1, vim.api.nvim_buf_line_count(buf), lines)
    put_ends(buf)
end

--- Redraws the rows of the plugins in `dirty` (a set of names), the header and the footer. Draws everything
--- instead when the order of the plugins changed, because one loaded or one was never drawn. Returns true
--- when it drew everything.
function M.refresh(buf, dirty)
    local list = stats.plugins()
    local same = #list == #names
    for i, row in ipairs(list) do
        same = same and names[i] == row.name
    end
    if not same then
        M.draw(buf, list)
        return true
    end
    for _, row in ipairs(list) do
        if dirty[row.name] then
            rows[row.name] = row
            put(buf, line_of[row.name], 1, { row_line(row) })
        end
    end
    put_ends(buf)
    return false
end

--- Where the window goes: centered, as wide and tall as the last full draw made it.
function M.config()
    local lines = vim.o.lines - vim.o.cmdheight
    return {
        relative = 'editor',
        width = view.width,
        height = view.height,
        row = math.max(math.floor((lines - view.height - 2) / 2), 0),
        col = math.max(math.floor((vim.o.columns - view.width - 2) / 2), 0),
    }
end

--- The line to keep in view: the last plugin at work, else the last failed one, else the header.
function M.target()
    local active, failed
    for _, name in ipairs(names) do
        local state = rows[name].state
        if ACTIVE[state] then
            active = line_of[name]
        elseif state == 'failed' then
            failed = line_of[name]
        end
    end
    return active or failed or 1
end

--- What a line shows, or nil for the header and footer.
function M.entry_at(lnum) return entries[lnum] end

return M
