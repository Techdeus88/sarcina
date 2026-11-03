-- sarcina/window.lua
-- The floating window, read from the stats: on the left a header, one row per plugin in the order they
-- loaded, and a footer; on the right the details of the plugin under the cursor. It keeps no task state,
-- only the rows it last drew, so an event redraws just the lines that changed.
-- ui.lua decides when the window opens, which plugins changed, and owns the windows themselves.

local paths = require('sarcina.paths')
local stats = require('sarcina.stats')

local function plural(count, word) return require('sarcina.ui').plural(count, word) end

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
    SarcinaBrand = 'Title',
    SarcinaFooter = 'Comment',
    SarcinaPickOn = 'DiagnosticOk',
    SarcinaPickOff = 'Comment',
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
    SarcinaSection = 'Function',
    SarcinaUpdate = 'DiagnosticInfo',
    SarcinaRev = 'Constant',
    SarcinaCommit = 'Special',
    SarcinaBreaking = 'DiagnosticError',
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

-- A name is cut to no less than this when the row has no room for it.
local NAME_MIN = 10
local KEY_W = 9
-- The window takes 80% of the editor each way: a header across the top, a footer across the bottom, and
-- between them the list and the details, which scroll. The view says how much of the width is the list's: 70% in
-- `main`, half in `split`. The details pane only exists when both panes have this much room.
local SHARE, LIST_MIN, DETAIL_MIN = 0.8, 40, 28
local VIEWS = { main = 0.7, split = 0.5 }
-- The share of the editor's height the window takes. The header and the footer keep theirs, so the extra rows of
-- `extended` all go to the list and the details.
local HEIGHTS = { regular = SHARE, extended = 0.95 }

local entries = {} -- line number -> { kind = 'plugin', name = string }
local line_of = {} -- plugin name -> line number
local update_line_of = {} -- plugin name -> the line of its update
local rows = {} -- plugin name -> the row as last drawn
local names = {} -- plugin names in line order
local selected = nil -- the plugin the details pane shows
local revs = {} -- plugin name -> short commit, '' when there is none, false while it is being read
local details_buf = nil -- the buffer the details were last drawn in
local marked = {} -- plugin name -> true for the plugins picked in the select view
-- Fixed at each full draw, so streaming output never resizes the window.
local view = {
    outer_w = 0, -- the whole window with its borders
    outer_h = 0,
    full_w = 0, -- inner width of the header and the footer
    middle = 0, -- inner height of the list and the details
    total_h = 0, -- the four windows stacked, borders included
    list_w = 0, -- inner width of the list
    detail_w = 0, -- inner width of the details, nil when there is no details pane
}

-- The header is two lines and the footer one, each with two borders.
local HEADER_OUTER, FOOTER_OUTER = 4, 3

--- Whether the tasks widget has rounded ends. They are Powerline glyphs, which need a patched font; without
--- one, set `ui = { rounded = false }` in setup() for flat ends.
M.rounded = true

--- How the list and the details share the width: 'main' (70/30) or 'split' (50/50).
M.view = 'main'

--- The last message for the right of the header, `{ level, text }`, and the question waiting for an answer,
--- `{ prompt }`. The UI sets them; the window only draws them.
M.message = nil
M.question = nil

--- Whether the list is in the select view: a checkbox in front of every row, and the footer names the picks.
M.select_mode = false

--- Whether the details show the changelog of a plugin that has an update, instead of its tasks.
M.changelog = false

local function checker() return require('sarcina.checker') end

-- The list has a section per timing, in this order, each with its plugins in the order they loaded.
local SECTIONS = {
    { timing = 'now', title = 'Now' },
    { timing = 'later', title = 'Later' },
    { timing = 'trigger', title = 'Triggered' },
}

--- Whether `name` is a view.
function M.is_view(name) return VIEWS[name] ~= nil end

--- Switches the details between the tasks of a plugin and, for one with an update, its changelog.
function M.toggle_changelog() M.changelog = not M.changelog end

--- Switches between the two views. Returns the view now in use.
function M.toggle_view()
    M.view = M.view == 'main' and 'split' or 'main'
    return M.view
end

--- How tall the window is: 'regular' (80% of the editor) or 'extended' (95%, the extra rows for the list).
M.height = 'regular'

--- Whether `name` is a height.
function M.is_height(name) return HEIGHTS[name] ~= nil end

--- Switches between the two heights. Returns the height now in use.
function M.toggle_height()
    M.height = M.height == 'regular' and 'extended' or 'regular'
    return M.height
end

-- How far a row of a section sits in from its header.
local INDENT = '   '

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
    local parts = {}
    if M.rounded then table.insert(parts, { CAP_LEFT, kind .. 'Left' }) end
    table.insert(parts, { string.format(' %d/%d ', task, tasks), kind .. 'Count' })
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
        '%s · %d loaded · %d not loaded · %d now · %d later · %d triggered · %s',
        plural(numbers.count, 'plugin'),
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

-- The three cells in front of a name: a plain indent, or in the select view a box that is checked for a pick.
local function lead_parts(name)
    if not M.select_mode then return { { INDENT } } end
    if marked[name] then return { { ' ' }, { '✔', 'SarcinaPickOn' }, { ' ' } } end
    return { { ' ' }, { '○', 'SarcinaPickOff' }, { ' ' } }
end

-- A row: `name (load time) when it loads <done>/<all> tasks pill status message`, one space apart. The status
-- message takes what is left of the list, so git's progress and a build's output show while they run. Without
-- room for a few characters of it the message goes, and only then is the name cut.
local function row_line(row)
    local time = format_time(row.duration)
    local after = {}
    if time ~= '' then vim.list_extend(after, { { ' ' }, { '(' .. time .. ')', 'SarcinaNote' } }) end
    if row.timing then vim.list_extend(after, { { ' ' }, { row.timing, 'SarcinaTag' } }) end
    table.insert(after, { ' ' })
    vim.list_extend(after, pill_parts(row.task, row.tasks, row.state))
    local lead = lead_parts(row.name)
    local name = fit(row.name, math.max(view.list_w - parts_width(lead) - parts_width(after), NAME_MIN))
    local parts = lead
    table.insert(parts, { name, 'SarcinaName' })
    vim.list_extend(parts, after)
    local left = view.list_w - parts_width(parts) - 1
    if left >= 4 then
        table.insert(parts, { ' ' })
        table.insert(parts, { fit(status_message(row), left), HL[row.state] })
    end
    return build_line(parts)
end

local function short(commit) return commit:sub(1, 7) end

local function breaking_count(commits)
    local count = 0
    for _, commit in ipairs(commits or {}) do
        if commit.breaking then count = count + 1 end
    end
    return count
end

-- A section header: its title and how many lines it holds, then `extra` parts.
local function section_line(title, count, extra)
    local parts = { { ' ' }, { string.format('%s (%d)', title, count), 'SarcinaSection' } }
    return build_line(vim.list_extend(parts, extra or {}))
end

-- The title of the list window while a check runs or after one that had something to check, on the top border
-- level with the name of the plugin over the details: `Updates (N)`, then that a check runs, that nothing was
-- found, how many remotes could not say, and the key for the changelog. '' for no title.
local function updates_title()
    local check = checker().state()
    if not (check.running or check.total > 0) then return '' end
    local found = vim.tbl_count(check.updates)
    local parts = { { string.format(' Updates (%d) ', found), 'SarcinaSection' } }
    if check.running then
        table.insert(parts, { '↻ checking… ', 'SarcinaNote' })
    elseif found == 0 then
        table.insert(parts, { '✔ up to date ', 'SarcinaDone' })
    end
    local failed = vim.tbl_count(check.failed)
    if failed > 0 then table.insert(parts, { plural(failed, 'remote') .. ' failed ', 'SarcinaFailed' }) end
    if found > 0 then table.insert(parts, { '<CR> changelog ', 'SarcinaNote' }) end
    return parts
end

-- What an update says after the commit it goes to: how far behind the plugin is and how many of those commits
-- break something.
local function behind(info)
    if not info.commits then return { { ' · update available' } } end
    if #info.commits == 0 then return { { ' · moves back' } } end
    local parts = { { ' · ' .. plural(#info.commits, 'commit') .. ' behind' } }
    local broken = breaking_count(info.commits)
    if broken > 0 then table.insert(parts, { '  △ ' .. broken .. ' breaking', 'SarcinaBreaking' }) end
    return parts
end

-- A row of the Updates section: `↑ name commit subject · N commits behind  △ N breaking`. The subject of the
-- newest commit takes what is left of the list, and goes when that is too little to say anything.
local function update_line(name, info)
    -- The arrow sits one cell in from the names of the rows below, and in the select view behind the pick box.
    local head = lead_parts(name)
    vim.list_extend(head, {
        { ' ' },
        { '↑ ', 'SarcinaUpdate' },
        { name, 'SarcinaName' },
        { ' ' },
        { short(info.to), 'SarcinaRev' },
    })
    local tail = behind(info)
    local newest = info.commits and info.commits[1]
    local room = view.list_w - parts_width(head) - parts_width(tail) - 1
    if newest and room >= 8 then table.insert(head, { ' ' .. fit(newest.subject, room), 'SarcinaCommit' }) end
    return build_line(vim.list_extend(head, tail))
end

-- The rows of `list` grouped by section, each group in the order of `list`. A row with no known timing is later.
local function grouped(list)
    local by_timing = {}
    for _, section in ipairs(SECTIONS) do
        by_timing[section.timing] = {}
    end
    for _, row in ipairs(list) do
        table.insert(by_timing[row.timing] or by_timing.later, row)
    end
    return by_timing
end

-- The names of `list` in the order the sections show them.
local function shown_order(list)
    local order, by_timing = {}, grouped(list)
    for _, section in ipairs(SECTIONS) do
        for _, row in ipairs(by_timing[section.timing]) do
            table.insert(order, row.name)
        end
    end
    return order
end

-- The lines of the list: the updates a check found, under the Updates title of the window, then a section per
-- timing. Sections are a blank line apart. Fills `entries`, `line_of`, `rows` and `names`.
local function layout(list)
    local lines = {}
    local function add(line, entry)
        table.insert(lines, line)
        entries[#lines] = entry
    end
    -- A blank line above the content and one below it, so it does not touch the borders.
    add(build_line({}), { kind = 'blank' })
    local check = checker().state()
    local found = {}
    for _, row in ipairs(list) do
        if check.updates[row.name] then table.insert(found, row.name) end
    end
    -- Sarcina is no row of the list, so its own update leads the list (see self.lua).
    local own = require('sarcina.self').name
    if check.updates[own] and not vim.tbl_contains(found, own) then table.insert(found, 1, own) end
    for _, name in ipairs(found) do
        add(update_line(name, check.updates[name]), { kind = 'update', name = name })
        update_line_of[name] = #lines
    end
    local by_timing = grouped(list)
    for _, section in ipairs(SECTIONS) do
        local members = by_timing[section.timing]
        if #members > 0 then
            if #lines > 1 then add(build_line({}), { kind = 'blank' }) end
            add(section_line(section.title, #members), { kind = 'section' })
            for _, row in ipairs(members) do
                table.insert(names, row.name)
                rows[row.name] = row
                add(row_line(row), { kind = 'plugin', name = row.name })
                line_of[row.name] = #lines
            end
        end
    end
    add(build_line({}), { kind = 'blank' })
    return lines
end

-- One line of `width`: `left` at the start, `center` in the middle and `right` at the end. The center moves over
-- for a long left, and a right with no room after what is before it is left out.
local function spread(width, left, center, right)
    local parts = vim.list_extend({}, left)
    local used = parts_width(left)
    if center then
        local at = math.max(math.floor((width - parts_width(center)) / 2), used > 0 and used + 1 or 0)
        table.insert(parts, { string.rep(' ', at - used) })
        vim.list_extend(parts, center)
        used = at + parts_width(center)
    end
    if right and #right > 0 then
        local at = width - parts_width(right)
        if at > used then
            table.insert(parts, { string.rep(' ', at - used) })
            vim.list_extend(parts, right)
        end
    end
    return build_line(parts)
end

-- The kinds of work the header follows as it happens, in the order it looks for them.
local ACTIVITY = {
    { id = 'install', icon = '⤓', label = 'Installing' },
    { id = 'update', icon = '↑', label = 'Updating' },
    { id = 'check', icon = '↻', label = 'Checking' },
    { id = 'build', icon = '⚙', label = 'Building' },
}
local BAR_W = 10

-- The work going on now, for the right of the header: what kind, how many of those jobs ended out of all of them,
-- the plugin at it, a bar and how far along, within `room` columns. A background check for updates counts too.
-- Nothing when idle.
local function activity_parts(room)
    local kind, finished, total, current
    local jobs = require('sarcina.tasks').snapshot().jobs
    for _, candidate in ipairs(ACTIVITY) do
        local ended, all, running = 0, 0, nil
        for _, job in ipairs(jobs) do
            if job.id == candidate.id and job.status ~= 'skipped' then
                all = all + 1
                if job.status == 'done' or job.status == 'failed' then ended = ended + 1 end
                if job.status == 'running' then running = job.plugin end
            end
        end
        if running then
            kind, finished, total, current = candidate, ended, all, running
            break
        end
    end
    if not kind then
        local check = checker().state()
        if not check.running then return {} end
        kind, finished, total = { icon = '↻', label = 'Checking for updates' }, check.checked, check.total
    end
    local share = total > 0 and finished / total or 0
    local filled = math.floor(share * BAR_W + 0.5)
    local head = {
        { kind.icon .. ' ' .. kind.label .. ' ', 'SarcinaRunning' },
        { string.format('%d/%d', finished, total), 'SarcinaStepTime' },
        { ' ' .. (total == 1 and 'plugin' or 'plugins'), 'SarcinaNote' },
    }
    local name = current and { { ' · ' .. current, 'SarcinaName' } } or {}
    local bar = {
        { '  ' },
        { string.rep('█', filled), 'SarcinaRunning' },
        { string.rep('░', BAR_W - filled), 'SarcinaNote' },
    }
    local percent = { { string.format(' %3d%% ', math.floor(share * 100 + 0.5)), 'SarcinaNote' } }
    -- With little room the name of the plugin goes first, then the bar.
    for _, pieces in ipairs({ { head, name, bar, percent }, { head, bar, percent }, { head, percent } }) do
        local parts = {}
        for _, piece in ipairs(pieces) do
            vim.list_extend(parts, piece)
        end
        if not room or parts_width(parts) <= room then return parts end
    end
    return {}
end

-- What the session did so far, for the left of the header next to the loaded and not loaded counts: an icon and
-- a number for the clones, the builds that ran, the updates that moved a plugin, the deletes and the failures,
-- each only when there was one.
local function totals_parts()
    local count = { install = 0, build = 0, update = 0, failed = 0 }
    for _, job in ipairs(require('sarcina.track').history()) do
        if job.status == 'failed' then
            count.failed = count.failed + 1
        elseif job.status == 'done' then
            if (job.id == 'install' or job.id == 'build') and job.working then
                count[job.id] = count[job.id] + 1
            elseif job.id == 'update' and (job.note or ''):find('→', 1, true) then
                count.update = count.update + 1
            end
        end
    end
    local parts = {}
    for _, total in ipairs({
        { count.install, '⤓', 'SarcinaDone' },
        { count.build, '⚙', 'SarcinaStepBuild' },
        { count.update, '↑', 'SarcinaUpdate' },
        { require('sarcina.installer').removed, '✕', 'SarcinaNote' },
        { count.failed, '✘', 'SarcinaFailed' },
    }) do
        if total[1] > 0 then
            table.insert(parts, { '  ' })
            table.insert(parts, { total[2], total[3] })
            table.insert(parts, { ' ' .. total[1], 'SarcinaStepTime' })
        end
    end
    return parts
end

local MESSAGE = {
    [vim.log.levels.INFO] = { '›', 'SarcinaName' },
    [vim.log.levels.WARN] = { '!', 'SarcinaWaiting' },
    [vim.log.levels.ERROR] = { '✘', 'SarcinaFailed' },
}

-- `text` as one line of the header's right side, cut to `room` columns. Nothing when there is no room.
local function right_text(icon, text, group, room)
    if room < 8 then return {} end
    text = (text:gsub('%s*\n%s*', ' · '))
    return { { icon .. ' ', group }, { fit(text, room - 3), group }, { ' ' } }
end

-- The right side of the two header lines, after the messages and questions the UI has for it. A question takes both
-- lines: what is asked, then the rest of it and the keys. Realtime work goes on the first line while there is no
-- question, and the last message on the second.
local function right_side(used_first, used_second)
    local room_first, room_second = view.full_w - used_first - 2, view.full_w - used_second - 2
    if M.question then
        local head, rest = M.question.prompt:match('^([^\n]*)\n?(.*)$')
        local keys = '[y] yes  [n] no'
        -- The keys always stay; the note before them is cut when there is no room.
        local second = keys
        if rest ~= '' then
            local note = (rest:gsub('%s*\n%s*', ' · '))
            second = fit(note, math.max(room_second - width_of(keys) - 5, 4)) .. '  ' .. keys
        end
        return right_text('?', head, 'SarcinaWaiting', room_first),
            right_text('', second, 'SarcinaWaiting', room_second)
    end
    local first = activity_parts(room_first)
    local second = {}
    local message = M.message
    if message then
        local style = MESSAGE[message.level] or MESSAGE[vim.log.levels.INFO]
        second = right_text(style[1], message.text, style[2], room_second)
    end
    return first, second
end

-- The header: the total and the work going on now, then how many plugins loaded and did not and what the session
-- did, how far all their tasks have got in the middle, and the last message.
-- The name in the middle of the first line of the header.
local BRAND = { { 'Sarcina', 'SarcinaBrand' } }

local function header_lines()
    local text = ' Total: ' .. plural(#names, 'plugin')
    local task, tasks, loaded = 0, 0, 0
    for _, name in ipairs(names) do
        task, tasks = task + rows[name].task, tasks + rows[name].tasks
        if rows[name].state == 'loaded' then loaded = loaded + 1 end
    end
    local counts = {
        { ' ' },
        { '●', 'SarcinaDone' },
        { ' ' .. loaded, 'SarcinaStepTime' },
        { '  ' },
        { '○', 'SarcinaPending' },
        { ' ' .. (#names - loaded), 'SarcinaStepTime' },
    }
    vim.list_extend(counts, totals_parts())
    local progress =
        { { tostring(task), 'SarcinaStepTime' }, { '/' .. plural(tasks, 'task'), 'SarcinaNote' } }
    local function center_end(parts)
        return math.floor((view.full_w - parts_width(parts)) / 2) + parts_width(parts)
    end
    local first, second = right_side(
        math.max(width_of(text), center_end(BRAND)),
        math.max(parts_width(counts), center_end(progress))
    )
    return {
        spread(view.full_w, { { text, 'SarcinaHeader' } }, BRAND, first),
        spread(view.full_w, counts, progress, second),
    }
end

-- A pick as a small pill in the colour of a loaded plugin: a check, then the name.
local function chip_parts(name)
    local parts = {}
    if M.rounded then table.insert(parts, { CAP_LEFT, 'SarcinaPillDoneLeft' }) end
    table.insert(parts, { ' ✔ ', 'SarcinaPillDoneCount' })
    table.insert(parts, { ' ' .. name .. ' ', 'SarcinaPillDone' })
    if M.rounded then table.insert(parts, { CAP_RIGHT, 'SarcinaPillDoneRight' }) end
    return parts
end

-- What the footer says on the left: the picks of the select view as pills, as many as fit, then `+N`. Outside the
-- select view, a pointer to it.
local function picks_parts(room)
    if not M.select_mode then return { { ' v to select plugins', 'SarcinaFooter' } } end
    local picked = M.marked()
    if #picked == 0 then return { { ' Space picks a plugin · v leaves', 'SarcinaFooter' } } end
    local parts = { { ' Selected ', 'SarcinaFooter' }, { tostring(#picked), 'SarcinaStepTime' }, { ' ' } }
    local used = parts_width(parts)
    for i, name in ipairs(picked) do
        local chip = chip_parts(name)
        local more = #picked - i
        local tail = more > 0 and width_of(' +' .. more) or 0
        if used + 1 + parts_width(chip) + tail > room then
            table.insert(parts, { ' +' .. (#picked - i + 1), 'SarcinaFooter' })
            return parts
        end
        table.insert(parts, { ' ' })
        vim.list_extend(parts, chip)
        used = used + 1 + parts_width(chip)
    end
    return parts
end

-- The picks on the left and the startup time on the right.
local function footer_lines()
    local numbers = stats.get()
    local right = numbers.startup_ms and string.format('Startup: %.0fms ', numbers.startup_ms)
        or 'Startup: … '
    local left = picks_parts(view.full_w - width_of(right) - 1)
    local gap = view.full_w - parts_width(left) - width_of(right)
    if gap < 1 then return { build_line(left) } end
    table.insert(left, { string.rep(' ', gap) })
    table.insert(left, { right, 'SarcinaFooter' })
    return { build_line(left) }
end

-- Fixes the sizes from the editor: the window is 80% by 80% of it. With room for it the details get a pane of
-- their own, as wide as the view says; without it the list takes the whole width.
local function measure()
    local lines = vim.o.lines - vim.o.cmdheight
    view.outer_w = math.max(math.floor(vim.o.columns * SHARE), 20)
    view.outer_h = math.max(math.floor(lines * HEIGHTS[M.height]), 5)
    view.full_w = view.outer_w - 2

    local inner = view.outer_w - 4
    local list_w = math.floor(inner * VIEWS[M.view])
    local detail_w = inner - list_w
    if list_w >= LIST_MIN and detail_w >= DETAIL_MIN then
        view.list_w, view.detail_w = list_w, detail_w
    else
        view.list_w, view.detail_w = view.outer_w - 2, nil
    end

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
    entries, line_of, rows, names, update_line_of = {}, {}, {}, {}, {}
    measure()
    local lines = layout(list)
    vim.api.nvim_buf_clear_namespace(bufs.list, NS, 0, -1)
    put(bufs.list, NS, 1, vim.api.nvim_buf_line_count(bufs.list), #lines > 0 and lines or { build_line({}) })
    put_chrome(bufs)
    if not (selected and (line_of[selected] or update_line_of[selected])) then selected = names[1] end
    for name in pairs(marked) do
        if not line_of[name] then marked[name] = nil end
    end
end

--- Redraws the rows of the plugins in `dirty` (a set of names), the header and the footer. Draws everything
--- instead when the order of the plugins changed, because one loaded or one was never drawn. Returns true
--- when it drew everything.
function M.refresh(bufs, dirty)
    local list = stats.plugins()
    local order = shown_order(list)
    local same = #order == #names
    for i, name in ipairs(order) do
        same = same and names[i] == name
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
        list = {
            relative = 'editor',
            row = middle_row,
            col = col,
            width = view.list_w,
            height = view.middle,
            title = updates_title(),
            title_pos = 'left',
        },
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
    return active or failed or line_of[names[1]] or 1
end

--- What a line of the list shows.
function M.entry_at(lnum) return entries[lnum] end

--- The line a plugin is on, or nil.
function M.line(name) return line_of[name] end

--- The picked plugins, in list order. After a draw, a plugin that left the list is no longer picked.
function M.marked()
    local picked = {}
    for _, name in ipairs(names) do
        if marked[name] then table.insert(picked, name) end
    end
    return picked
end

--- Enters or leaves the select view. Leaving it drops every pick.
function M.toggle_select_mode()
    M.select_mode = not M.select_mode
    if not M.select_mode then marked = {} end
end

--- Picks `name`, or drops it when it was picked. Only in the select view.
function M.toggle_mark(name)
    if M.select_mode and name then marked[name] = not marked[name] or nil end
end

--- Drops every pick but stays in the select view.
function M.clear_marks() marked = {} end

--- The plugin the details show.
function M.selected() return selected end

--- The cursor is on line `lnum` of the list: the details show the plugin of that row, and nothing when the line
--- names no plugin.
function M.select(lnum)
    local entry = entries[lnum]
    selected = entry and entry.name or nil
end

--- The line of a plugin nearest line `lnum`, looking `step` (1 down, -1 up) first and then the other way, or nil
--- when the list has no plugin. The cursor only rests on rows of plugins.
function M.nearest(lnum, step)
    for _, way in ipairs({ step, -step }) do
        local at = lnum
        while entries[at] do
            if entries[at].name then return at end
            at = at + way
        end
    end
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

-- Under a Tasks title, a line per task of the plugin's plan with its own time and note.
local function task_lines(name)
    local lines = { build_line({ { 'Tasks', 'SarcinaHeader' } }) }
    for _, step in ipairs(stats.steps(name)) do
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
    return lines
end

-- Under a Changelog title, a line per commit of an update, newest first; a breaking one is red and marked.
local function changelog_lines(commits)
    local lines = { build_line({ { 'Changelog', 'SarcinaHeader' } }) }
    for _, commit in ipairs(commits) do
        table.insert(
            lines,
            build_line({
                { ' ' },
                { commit.breaking and '△ ' or '  ', 'SarcinaBreaking' },
                { short(commit.sha), 'SarcinaRev' },
                { ' ' .. commit.subject, commit.breaking and 'SarcinaBreaking' or 'SarcinaCommit' },
            })
        )
    end
    return lines
end

-- The details of Sarcina's own update: where it runs from, its commit, the update and the commits it brings.
-- What Sarcina follows, in words: `branch stable`, or the pin of setup().
local function own_pin()
    local entry = require('sarcina.self').entry()
    local pin = entry and require('sarcina.pin').of(entry.spec)
    return pin and require('sarcina.pin').describe(pin) or ''
end

local function own_lines(info)
    local dir = require('sarcina.self').dir()
    local function fact(key, value, group)
        return build_line({ { pad(key, KEY_W + 1), 'SarcinaTag' }, { value, group } })
    end
    local lines = {
        fact('state', '↑ update available', 'SarcinaUpdate'),
        fact('path', vim.fn.fnamemodify(dir, ':~')),
        fact('rev', rev_of(require('sarcina.self').name, dir)),
        fact('pin', own_pin()),
        build_line(
            vim.list_extend(
                { { pad('update', KEY_W + 1), 'SarcinaTag' }, { short(info.to), 'SarcinaRev' } },
                behind(info)
            )
        ),
        fact('restart', 'after :Sarcina update, to load it', 'SarcinaNote'),
        build_line({}),
    }
    return vim.list_extend(lines, changelog_lines(info.commits or {}))
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
        local info = checker().update_of(selected)
        if info then
            local parts = { { pad('update', KEY_W + 1), 'SarcinaTag' }, { short(info.to), 'SarcinaRev' } }
            table.insert(lines, build_line(vim.list_extend(parts, behind(info))))
        end
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
        if M.changelog and info and info.commits then
            vim.list_extend(lines, changelog_lines(info.commits))
        else
            vim.list_extend(lines, task_lines(selected))
        end
    end
    local own = not row and selected == require('sarcina.self').name and checker().update_of(selected)
    if own then lines = own_lines(own) end
    if #lines > 0 then
        -- A blank line above the details and one below them, as in the list.
        table.insert(lines, 1, build_line({}))
        table.insert(lines, build_line({}))
    end
    vim.api.nvim_buf_clear_namespace(buf, DETAIL_NS, 0, -1)
    put(buf, DETAIL_NS, 1, vim.api.nvim_buf_line_count(buf), #lines > 0 and lines or { build_line({}) })
    return (row or own) and selected or nil
end

return M
