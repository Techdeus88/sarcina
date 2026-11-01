-- sarcina/track.lua
-- The lifecycle of every task. The runner calls `created`, `started` and `finished`, and they write
-- the timing onto the job itself, so the panel and the stats read one record. The history keeps every
-- job of the session, because a fresh run replaces the runner's job list.

local M = {}

local history = {}

local function ms(from, to) return (to - from) / 1e6 end

--- A job exists: stamp it and keep it.
function M.created(job)
    job.created = vim.uv.hrtime()
    table.insert(history, job)
end

--- A job began running. A retry keeps the first start.
function M.started(job) job.started = job.started or vim.uv.hrtime() end

--- A job ended, ok or not: `duration` is the end minus the first start, in ms.
function M.finished(job)
    job.ended = vim.uv.hrtime()
    job.duration = ms(job.started, job.ended)
end

--- Every job of the session, as the live tables.
function M.history() return history end

--- One copy per job, with times in ms since `origin` (an hrtime). A job that never ran has only `created`.
function M.records(origin)
    local records = {}
    for _, job in ipairs(history) do
        local record = {
            plugin = job.plugin,
            id = job.id,
            type = job.type,
            status = job.status,
            attempts = job.attempts,
            note = job.note,
            error = job.error,
            meta = job.spec.meta,
            created = ms(origin, job.created),
        }
        if job.started then
            record.started = ms(origin, job.started)
            record.waited = ms(job.created, job.started)
        end
        if job.ended then
            record.ended = ms(origin, job.ended)
            record.duration = job.duration
        end
        table.insert(records, record)
    end
    return records
end

--- Forget the history. For tests.
function M._reset() history = {} end

return M
