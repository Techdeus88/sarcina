-- sarcina/track.lua
-- The lifecycle of every task. The runner calls `created`, `started` and `finished`, and they write
-- the timing onto the job itself, so the panel and the stats read one record. The history keeps every
-- job of the session, because a fresh run replaces the runner's job list.

local M = {}

local history = {}
local by_plugin = {}
local ended = {} -- jobs in the order they ended

local function ms(from, to) return (to - from) / 1e6 end

--- A job exists: stamp it and keep it.
function M.created(job)
    job.created = vim.uv.hrtime()
    table.insert(history, job)
    by_plugin[job.plugin] = by_plugin[job.plugin] or {}
    table.insert(by_plugin[job.plugin], job)
end

--- A job began running. A retry keeps the first start.
function M.started(job) job.started = job.started or vim.uv.hrtime() end

--- A job ended, ok or not: `duration` is the end minus the first start, in ms. `at` is the hrtime the
--- executor said it was done, which can be earlier than now when the runner handles it later.
function M.finished(job, at)
    job.ended = at or vim.uv.hrtime()
    job.duration = ms(job.started, job.ended)
    table.insert(ended, job)
end

--- Every job of the session, as the live tables.
function M.history() return history end

--- Every job that ended, ok or not, in the order it ended, as the live tables. A retried job is in it
--- once per end. This is the record of the order things really happened in, such as plugins loading.
function M.finished_jobs() return ended end

--- The jobs of one plugin in creation order, as the live tables.
function M.jobs_of(name) return by_plugin[name] or {} end

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

--- Forget every job of the plugins `names`, so nothing in the session knows they ever ran.
function M.forget(names)
    local gone = {}
    for _, name in ipairs(names) do
        gone[name], by_plugin[name] = true, nil
    end
    local function kept(list)
        return vim.tbl_filter(function(job) return not gone[job.plugin] end, list)
    end
    history, ended = kept(history), kept(ended)
end

--- Forget the history. For tests.
function M._reset()
    history, by_plugin, ended = {}, {}, {}
end

return M
