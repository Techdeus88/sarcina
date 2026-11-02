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
    updating = '▶',
    checking = '▶',
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
    updating = 'SarcinaRunning',
    checking = 'SarcinaRunning',
    loading = 'SarcinaRunning',
    waiting = 'SarcinaWaiting',
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
local ACTIVE = { installing = true, building = true, updating = true, checking = true, loading = true }
local HL_LINKS = {
    SarcinaPending = 'Comment',
    SarcinaWaiting = 'DiagnosticWarn',
    SarcinaRunning = 'DiagnosticInfo',
    SarcinaDone = 'DiagnosticOk',
    SarcinaFailed = 'DiagnosticError',
    SarcinaSkipped = 'Comment',
    SarcinaNote = 'Comment',
    SarcinaName = 'Normal',
    SarcinaTag = 'Comment',
    SarcinaHeader = 'Title',
    SarcinaFooter = 'Comment',
    SarcinaStepInstall = 'Function',
    SarcinaStepBefore = 'Special',
    SarcinaStepBuild = 'Constant',
    SarcinaStepTrigger = 'Keyword',
    SarcinaStepRtp = 'String',
    SarcinaStepLoad = 'Type',
    SarcinaStepKeys = 'Identifier',
    SarcinaStepAfter = 'Statement',
    SarcinaStepUpdate = 'Number',
    SarcinaStepCheck = 'PreProc',
    SarcinaStepOther = 'Normal',
}
-- Each task of a plan has a colour of its own in the details, so the lines stand out from each other.
local STEP_GROUP = {
    install = 'SarcinaStepInstall',
    before = 'SarcinaStepBefore',
    build = 'SarcinaStepBuild',
    load_trigger = 'SarcinaStepTrigger',
    rtp = 'SarcinaStepRtp',
    load = 'SarcinaStepLoad',
    keys = 'SarcinaStepKeys',
    after = 'SarcinaStepAfter',
    update = 'SarcinaStepUpdate',
    check = 'SarcinaStepCheck',
}

local NAME_MAX, NAME_MIN, TAG_W = 28, 10, 7
-- The load time sits in brackets after the name: `(0.6ms)` at most `(<0.1ms)`. The status message takes what is
-- left of the list after the other columns, so git's progress and a build's output show while they run.
local TIME_COL = 8
local KEY_W = 9
-- The window takes 80% of the editor each way: a header across the top, a footer across the bottom, and
-- between them the list and the details, which scroll. The view says how much of the width is the list's: 70% in
-- `main`, half in `split`. The details pane only exists when both panes have this much room.
local SHARE, LIST_MIN, DETAIL_MIN = 0.8, 40, 28
local VIEWS = { main = 0.7, split = 0.5 }

local entries = {} -- line number -> { kind = 'plugin', name = string }
local line_of = {} -- plugin name -> line number
local rows = {} -- plugin name -> the row as last drawn
local names = {} -- plugin names in line order
local selected = nil -- the plugin the details pane shows
local revs = {} -- plugin name -> short commit, '' when there is none, false while it is being read
local details_buf = nil -- the buffer the details were last drawn in
-- Fixed at each full draw, so streaming output never resizes the window.
local view = {
    outer_w = 0, -- the whole window with its borders
    outer_h = 0,
    full_w = 0, -- inner width of the header and the footer
    middle = 0, -- inner height of the list and the details
    total_h = 0, -- the four windows stacked, borders included
    list_w = 0, -- inner width of the list
    detail_w = 0, -- inner width of the details, nil when there is no details pane
    name_w = 0,
    digits = 1, -- digits of the largest task count, so that every widget is as wide as the others
    message = 0, -- columns left for the status message of a row
}

-- The header is two lines and the footer one, each with two borders.
local HEADER_OUTER, FOOTER_OUTER = 4, 3

--- Whether the tasks widget has rounded ends. They are Powerline glyphs, which need a patched font; without
--- one, set `ui = { rounded = false }` in setup() for flat ends.
M.rounded = true

--- How the list and the details share the width: 'main' (70/30) or 'split' (50/50).
M.view = 'main'

--- Whether `name` is a view.
function M.is_view(name) return VIEWS[name] ~= nil end

--- Switches between the two views. Returns the view now in use.
function M.toggle_view()
    M.view = M.view == 'main' and 'split' or 'main'
    return M.view
end

local CAP_LEFT, CAP_RIGHT = vim.fn.nr2char(0xe0b6), vim.fn.nr2char(0xe0b4)

-- The tasks widget of a row is a button: rounded ends and two tones. The count (`3 of 8`) is in the colour of
-- the state, in dark bold text; the label (`tasks`) is a light tint of it, in a darker shade. `from` is the
-- group whose colour it takes, `fallback` is used when the colorscheme gives that group none.
local PILLS = {
    Done = { from = 'DiagnosticOk', fallback = 0x98c379 },
    Running = { from = 'DiagnosticInfo', fallback = 0x61afef },
    Waiting = { from = 'DiagnosticWarn', fallback = 0xe5c07b },
    Failed = { from = 'DiagnosticError', fallback = 0xe06c75 },
    Idle = { from = 'Comment', fallback = 0x9099a5 },
}
local PILL = {
    pending = 'Idle',
    installing = 'Running',
    building = 'Running',
    updating = 'Running',
    checking = 'Running',
    loading = 'Running',
    waiting = 'Waiting',
    loaded = 'Done',
    blocked = 'Idle',
    failed = 'Failed',
}

-- `color` moved `ratio` of the way to `toward`, both 0xRRGGBB.
local function mix(color, toward, ratio)
    local out = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
        local from = bit.band(bit.rshift(color, shift), 0xff)
        local to = bit.band(bit.rshift(toward, shift), 0xff)
        out = bit.bor(out, bit.lshift(math.floor(from + (to - from) * ratio + 0.5), shift))
    end
    return out
end

function M.define_highlights()
    for name, link in pairs(HL_LINKS) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
    -- The time of a task: bold and in the colour of the text, against the colour of the task beside it.
    vim.api.nvim_set_hl(
        0,
        'SarcinaStepTime',
        { bold = true, fg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).fg, default = true }
    )
    -- Each kind has four groups: the count, the label, and the two ends. An end only sets its foreground,
    -- so the cell behind it stays the window's (or the cursor line's) and the end looks round.
    for kind, pill in pairs(PILLS) do
        local color = vim.api.nvim_get_hl(0, { name = pill.from, link = false }).fg or pill.fallback
        local count_bg, label_bg = color, mix(color, 0xffffff, 0.8)
        local function set(suffix, attrs)
            vim.api.nvim_set_hl(
                0,
                'SarcinaPill' .. kind .. suffix,
                vim.tbl_extend('force', attrs, { default = true })
            )
        end
        set('Left', { fg = count_bg })
        set('Count', { fg = mix(color, 0x000000, 0.85), bg = count_bg, bold = true })
        set('', { fg = mix(color, 0x000000, 0.55), bg = label_bg })
        set('Right', { fg = label_bg })
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

-- The tasks widget as `{ text, group }` parts: the count (`3/8`), then the label with the icon of the state,
-- and rounded ends unless `rounded` is off. A loaded plugin has a check, one that waits for its trigger a
-- circle, one at work a triangle, and so on.
local function pill_parts(task, tasks, state)
    local kind = 'SarcinaPill' .. PILL[state]
    local digits = view.digits
    local parts = {}
    if M.rounded then table.insert(parts, { CAP_LEFT, kind .. 'Left' }) end
    table.insert(
        parts,
        { string.format(' %' .. digits .. 'd/%' .. digits .. 'd ', task, tasks), kind .. 'Count' }
    )
    table.insert(parts, { ' tasks ' .. GLYPH[state] .. ' ', kind })
    if M.rounded then table.insert(parts, { CAP_RIGHT, kind .. 'Right' }) end
    return parts
end

local function parts_width(parts)
    local width = 0
    for _, part in ipairs(parts) do
        width = width + width_of(part[1])
    end
    return width
end

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

-- What the row says about the state: its word, and what it adds, such as git's line or the error.
local function status_message(row)
    local detail = ((row.detail or ''):gsub('%s+', ' '))
    if detail == '' then return row.state end
    if vim.startswith(detail, row.state) then return detail end
    return row.state .. ' · ' .. detail
end

-- A row: `name  (load time) when it loads, <done>/<all> tasks pill, status message`.
local function row_line(row)
    local time = format_time(row.duration)
    local parts = {
        { ' ' },
        { pad(fit(row.name, view.name_w), view.name_w), 'SarcinaName' },
        { '  ' },
        { pad(time ~= '' and '(' .. time .. ')' or '', TIME_COL), 'SarcinaNote' },
        { ' ' },
        { pad(row.timing or '', TAG_W), 'SarcinaTag' },
        { ' ' },
    }
    vim.list_extend(parts, pill_parts(row.task, row.tasks, row.state))
    if view.message > 0 then
        table.insert(parts, { ' ' })
        table.insert(parts, { fit(status_message(row), view.message), HL[row.state] })
    end
    return build_line(parts)
end

local function header_lines()
    local text = string.format(' Total: %d plugin%s', #names, #names == 1 and '' or 's')
    local task, tasks = 0, 0
    for _, name in ipairs(names) do
        task, tasks = task + rows[name].task, tasks + rows[name].tasks
    end
    local count = string.format('%d/%d tasks', task, tasks)
    local lead = math.max(math.floor((view.full_w - width_of(count)) / 2), 0)
    return {
        build_line({ { fit(text, view.full_w), 'SarcinaHeader' } }),
        build_line({
            { string.rep(' ', lead) },
            { tostring(task), 'SarcinaStepTime' },
            { string.format('/%d tasks', tasks), 'SarcinaNote' },
        }),
    }
end

-- How many plugins load now, later and on a trigger, on the left, and the startup time on the right.
local function footer_lines()
    local numbers = stats.get()
    local left =
        string.format(' Now %d, Later %d, Triggered %d', numbers.now, numbers.later, numbers.triggered)
    local right = numbers.startup_ms and string.format('Startup: %.0fms ', numbers.startup_ms)
        or 'Startup: … '
    local gap = view.full_w - width_of(left) - width_of(right)
    if gap < 1 then return { build_line({ { fit(left, view.full_w), 'SarcinaFooter' } }) } end
    return { build_line({ { left, 'SarcinaFooter' }, { string.rep(' ', gap) }, { right, 'SarcinaFooter' } }) }
end

-- Fixes the sizes and the columns from the rows and the editor: the window is 80% by 80% of the editor. With
-- room for it the details get a pane of their own; without it the list takes the whole width. The name column
-- shrinks when the list is narrow, and the status message is what is left after the other columns.
local function measure(list)
    local name_w, max_tasks = 0, 0
    for _, row in ipairs(list) do
        name_w = math.max(name_w, width_of(row.name))
        max_tasks = math.max(max_tasks, row.tasks)
    end
    name_w = math.min(name_w, NAME_MAX)
    view.digits = #tostring(max_tasks)
    local pill_w = parts_width(pill_parts(max_tasks, max_tasks, 'loaded'))
    local without_name = 1 + 2 + TIME_COL + 1 + TAG_W + 1 + pill_w

    local lines = vim.o.lines - vim.o.cmdheight
    view.outer_w = math.max(math.floor(vim.o.columns * SHARE), 20)
    view.outer_h = math.max(math.floor(lines * SHARE), 5)
    view.full_w = view.outer_w - 2

    local inner = view.outer_w - 4
    local list_w = math.floor(inner * VIEWS[M.view])
    local detail_w = inner - list_w
    if list_w >= LIST_MIN and detail_w >= DETAIL_MIN then
        view.list_w, view.detail_w = list_w, detail_w
    else
        view.list_w, view.detail_w = view.outer_w - 2, nil
    end

    view.name_w = math.max(math.min(name_w, view.list_w - without_name), NAME_MIN)
    -- Less than a few characters of message says nothing, so the column goes.
    local left = view.list_w - without_name - view.name_w - 1
    view.message = left >= 4 and left or 0

    -- The header and the footer take what they need, and the list and the details the rest.
    local chrome = HEADER_OUTER + FOOTER_OUTER
    view.middle = math.max(view.outer_h - chrome - 2, 3)
    view.total_h = chrome + view.middle + 2
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

-- The header and the footer have buffers of their own, so they stay in view while the list scrolls.
local function put_chrome(bufs)
    put(bufs.header, NS, 1, vim.api.nvim_buf_line_count(bufs.header), header_lines())
    put(bufs.footer, NS, 1, vim.api.nvim_buf_line_count(bufs.footer), footer_lines())
end

--- Draws every row of the list from the stats, one per registered plugin in the order they loaded, and the
--- header and the footer. `bufs` is `{ list, header, footer }`, the three buffers. Fixes the sizes. `list`
--- is `stats.plugins()` when the caller already has it.
function M.draw(bufs, list)
    list = list or stats.plugins()
    entries, line_of, rows, names = {}, {}, {}, {}
    measure(list)
    local lines = {}
    for i, row in ipairs(list) do
        names[i] = row.name
        rows[row.name] = row
        line_of[row.name] = i
        entries[i] = { kind = 'plugin', name = row.name }
        lines[i] = row_line(row)
    end
    vim.api.nvim_buf_clear_namespace(bufs.list, NS, 0, -1)
    put(bufs.list, NS, 1, vim.api.nvim_buf_line_count(bufs.list), #lines > 0 and lines or { build_line({}) })
    put_chrome(bufs)
    if not (selected and line_of[selected]) then selected = names[1] end
end

--- Redraws the rows of the plugins in `dirty` (a set of names), the header and the footer. Draws everything
--- instead when the order of the plugins changed, because one loaded or one was never drawn. Returns true
--- when it drew everything.
function M.refresh(bufs, dirty)
    local list = stats.plugins()
    local same = #list == #names
    for i, row in ipairs(list) do
        same = same and names[i] == row.name
    end
    if not same then
        M.draw(bufs, list)
        return true
    end
    for _, row in ipairs(list) do
        if dirty[row.name] then
            rows[row.name] = row
            put(bufs.list, NS, line_of[row.name], 1, { row_line(row) })
        end
    end
    put_chrome(bufs)
    return false
end

--- Where the windows go. All four are stacked and centered, 80% by 80% of the editor: the header, then the
--- list and the details side by side, then the footer. `detail` is nil when there is no room for the details.
function M.config()
    local lines = vim.o.lines - vim.o.cmdheight
    local row = math.max(math.floor((lines - view.total_h) / 2), 0)
    local col = math.max(math.floor((vim.o.columns - view.outer_w) / 2), 0)
    local middle_row = row + HEADER_OUTER
    local config = {
        header = { relative = 'editor', row = row, col = col, width = view.full_w, height = 2 },
        list = { relative = 'editor', row = middle_row, col = col, width = view.list_w, height = view.middle },
        footer = {
            relative = 'editor',
            row = middle_row + view.middle + 2,
            col = col,
            width = view.full_w,
            height = 1,
        },
    }
    if view.detail_w then
        config.detail = {
            relative = 'editor',
            row = middle_row,
            col = col + view.list_w + 2,
            width = view.detail_w,
            height = view.middle,
        }
    end
    return config
end

--- The line to keep in view: the last plugin at work, else the last failed one, else the first.
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

--- What a line of the list shows.
function M.entry_at(lnum) return entries[lnum] end

--- The line a plugin is on, or nil.
function M.line(name) return line_of[name] end

--- The plugin the details show.
function M.selected() return selected end

--- The cursor is on line `lnum` of the list: the details show that plugin.
function M.select(lnum)
    local entry = entries[lnum]
    if entry then selected = entry.name end
end

--- The window closed: the next one starts with a fresh selection.
function M.closed() selected = nil end

--- Forget the commits that were read: a fresh run may have cloned or updated plugins.
function M.forget() revs = {} end

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
        local dir = paths.install(selected)
        local function add(key, value, group)
            if value == nil or value == '' then return end
            table.insert(lines, build_line({ { pad(key, KEY_W + 1), 'SarcinaTag' }, { value, group } }))
        end
        local triggered = type(spec.triggers) == 'table'
        add('state', GLYPH[row.state] .. ' ' .. row.state, HL[row.state])
        local widget = { { pad('tasks', KEY_W + 1), 'SarcinaTag' } }
        vim.list_extend(widget, pill_parts(row.task, row.tasks, row.state))
        if row.duration then table.insert(widget, { ' ' .. format_time(row.duration), 'SarcinaStepTime' }) end
        table.insert(lines, build_line(widget))
        add('timing', row.timing)
        add('src', spec.repo and require('sarcina.executors').clone_url(spec.repo) or nil)
        local pin = require('sarcina.pin').of(spec)
        add('pin', pin and require('sarcina.pin').describe(pin) or nil)
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
        table.insert(lines, build_line({ { 'Tasks', 'SarcinaHeader' } }))
        for _, step in ipairs(stats.steps(selected)) do
            local note, group = step_note(step)
            local time = format_time(step.duration)
            table.insert(
                lines,
                build_line({
                    { ' ' },
                    { STEP_GLYPH[step.status], STEP_HL[step.status] },
                    { ' ' },
                    { step.id, STEP_GROUP[step.id] or 'SarcinaStepOther' },
                    { time ~= '' and ' ' or '' },
                    { time, 'SarcinaStepTime' },
                    { note and '  ' .. (note:gsub('%s+', ' ')) or '', group },
                })
            )
        end
    end
    vim.api.nvim_buf_clear_namespace(buf, DETAIL_NS, 0, -1)
    put(buf, DETAIL_NS, 1, vim.api.nvim_buf_line_count(buf), #lines > 0 and lines or { build_line({}) })
    return row and selected or nil
end

return M
