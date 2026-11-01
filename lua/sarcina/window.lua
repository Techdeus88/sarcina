-- sarcina/window.lua
-- The floating window, read from the stats: on the left a header, one row per plugin in the order they
-- loaded, and a footer; on the right the details of the plugin under the cursor. It keeps no task state,
-- only the rows it last drew, so an event redraws just the lines that changed.
-- ui.lua decides when the window opens, which plugins changed, and owns the windows themselves.

local paths = require('sarcina.paths')
local stats = require('sarcina.stats')

local M = {}

local NS = vim.api.nvim_create_namespace('sarcina_window')
local DETAIL_NS = vim.api.nvim_create_namespace('sarcina_details')

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
local STEP_GLYPH = { pending = '…', running = '▶', done = '✔', failed = '✘', skipped = '⊘' }
local STEP_HL = {
    pending = 'SarcinaPending',
    running = 'SarcinaRunning',
    done = 'SarcinaDone',
    failed = 'SarcinaFailed',
    skipped = 'SarcinaSkipped',
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

local NAME_MAX, NAME_MIN, TAG_W, STATE_W, TIME_W, SLOWEST = 28, 10, 7, 10, 6, 3
local KEY_W, STEP_W = 9, 11
-- The window takes 80% of the editor each way. The list gets at most 55% of the width, and the details
-- pane only exists when both panes have this much room.
local SHARE, LIST_MIN, DETAIL_MIN = 0.8, 40, 36
local LIST_SHARE = 0.55

local entries = {} -- line number -> { kind = 'plugin', name = string }
local line_of = {} -- plugin name -> line number
local rows = {} -- plugin name -> the row as last drawn
local names = {} -- plugin names in line order
local selected = nil -- the plugin the details pane shows
local revs = {} -- plugin name -> short commit, '' when there is none, false while it is being read
local details_buf = nil -- the buffer the details were last drawn in
-- Fixed at each full draw, so streaming output never resizes the window.
local view = {
    outer_w = 0, -- both panes with their borders
    outer_h = 0,
    height = 0, -- inner height of each pane
    list_w = 0, -- inner width of the list
    detail_w = 0, -- inner width of the details, nil when there is no details pane
    name_w = 0,
    progress_w = 0,
    show_state = true,
    detail = 0, -- columns left for a row's detail text
    footer_n = 1, -- lines of the stats summary, which wraps
}

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

-- Packs the ' · ' separated parts of a summary into lines of at most `width` columns.
local function wrap_summary(text, width)
    local lines, current = {}, ''
    for _, part in ipairs(vim.split(text, ' · ', { plain = true })) do
        local candidate = current == '' and part or (current .. ' · ' .. part)
        if current ~= '' and width_of(candidate) > width then
            table.insert(lines, current)
            current = part
        else
            current = candidate
        end
    end
    if current ~= '' then table.insert(lines, current) end
    return lines
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
    local parts = {
        { ' ' },
        { GLYPH[row.state], group },
        { ' ' },
        { pad(fit(row.name, view.name_w), view.name_w), 'SarcinaName' },
        { ' ' },
        { pad(row.timing or '', TAG_W), 'SarcinaTag' },
    }
    if view.show_state then
        table.insert(parts, { ' ' })
        table.insert(parts, { pad(row.state, STATE_W), group })
    end
    table.insert(parts, { ' ' })
    table.insert(parts, { pad(progress_text(row.task, row.tasks), view.progress_w), 'SarcinaNote' })
    table.insert(parts, { ' ' })
    table.insert(parts, { string.rep(' ', TIME_W - width_of(time)) .. time, 'SarcinaNote' })
    if view.detail > 0 then
        local detail = (row.detail or ''):gsub('%s+', ' ')
        table.insert(parts, { ' ' })
        table.insert(
            parts,
            { fit(detail, view.detail), row.state == 'failed' and 'SarcinaFailed' or 'SarcinaNote' }
        )
    end
    return build_line(parts)
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
    return build_line({ { fit(text, view.list_w), 'SarcinaHeader' } })
end

-- The stats summary, wrapped to the list and padded to the lines the last full draw made room for, then
-- the slowest plugins.
local function footer_lines()
    local summary = wrap_summary(M.summary(stats.get()), view.list_w - 1)
    local lines = {}
    for i = 1, view.footer_n do
        local text = i == view.footer_n and table.concat(vim.list_slice(summary, i), ' · ')
            or summary[i]
            or ''
        lines[i] = build_line({ { fit(text ~= '' and ' ' .. text or '', view.list_w), 'SarcinaFooter' } })
    end
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
    table.insert(lines, build_line({ { fit(slow, view.list_w), 'SarcinaFooter' } }))
    return lines
end

-- Fixes the sizes and the columns from the rows and the editor: the window is 80% by 80% of the editor. With
-- room for it the details get a pane of their own; without it the list takes the whole width. The columns of
-- a row drop out when there is no room: its detail text first, then its state word, then the name shrinks.
local function measure(list)
    local name_w, progress_w = 0, 0
    for _, row in ipairs(list) do
        name_w = math.max(name_w, width_of(row.name))
        progress_w = math.max(progress_w, width_of(progress_text(row.tasks, row.tasks)))
    end
    name_w = math.min(name_w, NAME_MAX)
    local with_state = 3 + name_w + 1 + TAG_W + 1 + STATE_W + 1 + progress_w + 1 + TIME_W + 1
    local without_name = 3 + 1 + TAG_W + 1 + progress_w + 1 + TIME_W + 1

    local lines = vim.o.lines - vim.o.cmdheight
    view.outer_w = math.max(math.floor(vim.o.columns * SHARE), 20)
    view.outer_h = math.max(math.floor(lines * SHARE), 5)
    view.height = view.outer_h - 2

    local inner = view.outer_w - 4
    local list_w = math.min(with_state, math.floor(inner * LIST_SHARE))
    local detail_w = inner - list_w
    if list_w >= LIST_MIN and detail_w >= DETAIL_MIN then
        view.list_w, view.detail_w = list_w, detail_w
    else
        view.list_w, view.detail_w = view.outer_w - 2, nil
    end

    view.progress_w = progress_w
    view.show_state = view.list_w >= with_state
    view.name_w = view.show_state and name_w
        or math.max(math.min(name_w, view.list_w - without_name), NAME_MIN)
    local used = view.show_state and with_state or (without_name + view.name_w)
    -- Less than a few characters of detail says nothing, so the column goes.
    view.detail = view.list_w - used >= 4 and view.list_w - used or 0

    local n = #list
    local widest = M.summary({
        count = n,
        loaded = n,
        not_loaded = n,
        now = n,
        later = n,
        triggered = n,
        startup_ms = 99999,
    })
    view.footer_n = #wrap_summary(widest, view.list_w - 1)
end

-- Replaces `count` lines from line `first` (1-based) with `lines` and colours them.
local function put(buf, ns, first, count, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        buf,
        first - 1,
        first - 1 + count,
        false,
        vim.tbl_map(function(l) return l.text end, lines)
    )
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, first - 1, first - 1 + #lines)
    for i, line in ipairs(lines) do
        for _, mark in ipairs(line.marks) do
            vim.api.nvim_buf_set_extmark(
                buf,
                ns,
                first - 2 + i,
                mark[1],
                { end_col = mark[2], hl_group = mark[3] }
            )
        end
    end
end

local function put_ends(buf)
    put(buf, NS, 1, 1, { header_line() })
    put(buf, NS, #names + 2, view.footer_n + 1, footer_lines())
end

--- Draws every line of the list from the stats: one row per registered plugin, in the order they loaded.
--- Fixes the sizes. `list` is `stats.plugins()` when the caller already has it.
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
    for _ = 1, view.footer_n + 1 do
        table.insert(lines, build_line({}))
    end
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    put(buf, NS, 1, vim.api.nvim_buf_line_count(buf), lines)
    put_ends(buf)
    if not (selected and line_of[selected]) then selected = names[1] end
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
            put(buf, NS, line_of[row.name], 1, { row_line(row) })
        end
    end
    put_ends(buf)
    return false
end

--- Where the windows go: both panes together are centered and 80% by 80% of the editor. `detail` is nil
--- when there is no room for the details pane.
function M.config()
    local lines = vim.o.lines - vim.o.cmdheight
    local row = math.max(math.floor((lines - view.outer_h) / 2), 0)
    local col = math.max(math.floor((vim.o.columns - view.outer_w) / 2), 0)
    local config = {
        list = { relative = 'editor', row = row, col = col, width = view.list_w, height = view.height },
    }
    if view.detail_w then
        config.detail = {
            relative = 'editor',
            row = row,
            col = col + view.list_w + 2,
            width = view.detail_w,
            height = view.height,
        }
    end
    return config
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

--- What a line shows, or nil for the header and the footer.
function M.entry_at(lnum) return entries[lnum] end

--- The line a plugin is on, or nil.
function M.line(name) return line_of[name] end

--- The plugin the details show.
function M.selected() return selected end

--- The cursor is on line `lnum`: the details show that plugin. On the header or the footer they keep the
--- plugin they had.
function M.select(lnum)
    local entry = entries[lnum]
    if entry then selected = entry.name end
end

--- The window closed: the next one starts with a fresh selection.
function M.closed() selected = nil end

--- Forget the commits that were read: a fresh run may have cloned or updated plugins.
function M.forget() revs = {} end

local function location(name, spec) return spec and spec.dest or paths.install(name) end

-- The short commit of a plugin, read in the background. Asks for the details to be drawn again when it is in.
local function rev_of(name, dir)
    if revs[name] ~= nil then return revs[name] or '…' end
    revs[name] = false
    local function got(rev)
        revs[name] = rev
        if selected == name and details_buf and vim.api.nvim_buf_is_valid(details_buf) then
            M.draw_details(details_buf)
        end
    end
    local spawned = pcall(
        vim.system,
        { 'git', '-C', dir, 'rev-parse', '--short', 'HEAD' },
        { text = true },
        function(res)
            vim.schedule(function() got(res.code == 0 and vim.trim(res.stdout) or '') end)
        end
    )
    if not spawned then revs[name] = '' end
    return '…'
end

-- A running task says what it prints. A finished one keeps only its note, not the last line it printed.
local function step_note(step)
    if step.status == 'failed' then return step.error, 'SarcinaFailed' end
    if step.status == 'running' then return step.output or step.note, 'SarcinaNote' end
    return step.note, 'SarcinaNote'
end

--- Draws the details of the selected plugin in `buf`: its facts, then one line per task of its plan with
--- the task's own time. Returns the plugin's name, or nil when nothing is selected.
function M.draw_details(buf)
    details_buf = buf
    local row = selected and stats.plugin(selected)
    local lines = {}
    if row then
        local spec = (stats.spec(selected) or {}).spec or {}
        local dir = location(selected, spec)
        local function add(key, value, group)
            if value == nil or value == '' then return end
            table.insert(lines, build_line({ { pad(key, KEY_W + 1), 'SarcinaTag' }, { value, group } }))
        end
        local triggered = type(spec.triggers) == 'table'
        add('state', GLYPH[row.state] .. ' ' .. row.state, HL[row.state])
        add(
            'tasks',
            progress_text(row.task, row.tasks) .. (row.duration and ' · ' .. format_time(row.duration) or '')
        )
        add('timing', row.timing)
        add('src', spec.repo)
        add('path', vim.fn.fnamemodify(dir, ':~'))
        add('rev', rev_of(selected, dir))
        add('deps', type(spec.deps) == 'table' and table.concat(spec.deps, ', ') or nil)
        add('triggers', triggered and require('sarcina.scheduler').describe(spec.triggers) or nil)
        add('armed', triggered and require('sarcina.scheduler').state(selected) or nil)
        add('origin', spec.origin and vim.fn.fnamemodify(spec.origin, ':~') or nil)
        add(
            'detail',
            (row.detail or ''):gsub('%s+', ' '),
            row.state == 'failed' and 'SarcinaFailed' or 'SarcinaNote'
        )
        table.insert(lines, build_line({}))
        for _, step in ipairs(stats.steps(selected)) do
            local note, group = step_note(step)
            local time = format_time(step.duration)
            table.insert(
                lines,
                build_line({
                    { ' ' },
                    { STEP_GLYPH[step.status], STEP_HL[step.status] },
                    { ' ' },
                    { pad(step.id, STEP_W), 'SarcinaName' },
                    { string.rep(' ', TIME_W - width_of(time)) .. time, 'SarcinaNote' },
                    { note and ' ' .. (note:gsub('%s+', ' ')) or '', group },
                })
            )
        end
    end
    vim.api.nvim_buf_clear_namespace(buf, DETAIL_NS, 0, -1)
    put(buf, DETAIL_NS, 1, vim.api.nvim_buf_line_count(buf), #lines > 0 and lines or { build_line({}) })
    return row and selected or nil
end

return M
