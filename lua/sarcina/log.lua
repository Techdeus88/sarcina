-- sarcina/log.lua
-- The session's messages on disk, one line each: `2026-11-02 14:03:07 WARN  Not installed: x`. Messages show in the
-- header for a few seconds, and the log is where they stay. It is rotated once to `sarcina.log.1` past 512 KB.

local M = {}

local LIMIT = 512 * 1024
local NAMES = {
    [vim.log.levels.DEBUG] = 'DEBUG',
    [vim.log.levels.INFO] = 'INFO ',
    [vim.log.levels.WARN] = 'WARN ',
    [vim.log.levels.ERROR] = 'ERROR',
}
local checked = false

--- Where the log is.
function M.path() return vim.fn.stdpath('state') .. '/sarcina/sarcina.log' end

local function rotate(path)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.size > LIMIT then vim.uv.fs_rename(path, path .. '.1') end
end

--- Appends a line. A log that cannot be written is skipped, since it must never get in the way of the work.
function M.write(level, text)
    local path = M.path()
    if not checked then
        checked = true
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        rotate(path)
    end
    local file = io.open(path, 'a')
    if not file then return end
    file:write(
        os.date('%Y-%m-%d %H:%M:%S '),
        NAMES[level] or 'INFO ',
        ' ',
        (text:gsub('%s*\n%s*', ' | ')),
        '\n'
    )
    file:close()
end

--- Forget that the size was checked. For tests.
function M._reset() checked = false end

return M
