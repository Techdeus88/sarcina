-- sarcina/pin.lua
-- What a spec asks of git: `commit`, `tag`, `version` or `branch`. This module only reads specs and the refs
-- a remote listed; the git commands are in executors.lua.
--   commit    an exact commit, in full or abbreviated
--   tag       a tag
--   version   a semver range, as a string ('1.*', '^1.2') or vim.version.range(): the highest tag inside it.
--             Another string is a commit when it looks like one (hex, 7-40 characters with a letter in it),
--             and otherwise the name of a branch or tag.
--   branch    a branch, which `update` follows
-- When a spec sets more than one, the first of the list above wins.

local M = {}

local KEYS = { 'commit', 'tag', 'version', 'branch' }

local function text(value) return type(value) == 'string' and value ~= '' and value or nil end

local function is_range(value) return type(value) == 'table' and type(value.has) == 'function' end

local function range_text(range)
    local from, to = tostring(range.from), range.to and tostring(range.to)
    if not to then return '>=' .. from end
    return from == to and '=' .. from or '>=' .. from .. ' <' .. to
end

-- vim.version.range() takes 'b516f20b' for 516.0.0, so a string has to start like a range to be one.
local function version_pin(value)
    if is_range(value) then return { kind = 'version', value = range_text(value), range = value } end
    value = text(value)
    if not value then return nil end
    if #value >= 7 and #value <= 40 and value:match('^%x+$') and value:match('%a') then
        return { kind = 'commit', value = value }
    end
    if value:match('^[%s%^~<>=v]*[%d%*xX]') then
        local ok, range = pcall(vim.version.range, value)
        if ok and range then return { kind = 'version', value = value, range = range } end
    end
    return { kind = 'ref', value = value }
end

--- The pin a spec asks for, as { kind, value, range? }, or nil. The second result lists the keys that the
--- stronger one overruled.
function M.of(spec)
    local wanted = {
        commit = text(spec.commit) and { kind = 'commit', value = spec.commit },
        tag = text(spec.tag) and { kind = 'tag', value = spec.tag },
        version = version_pin(spec.version),
        branch = text(spec.branch) and { kind = 'branch', value = spec.branch },
    }
    local chosen, ignored
    for _, key in ipairs(KEYS) do
        if wanted[key] then
            if chosen then
                ignored = ignored or {}
                table.insert(ignored, key)
            else
                chosen = wanted[key]
            end
        end
    end
    return chosen, ignored
end

--- A pin in words, for the details and the messages.
function M.describe(pin) return pin.kind .. ' ' .. pin.value end

--- What the lock file keeps beside a commit, to tell that the spec still asks for the same.
function M.key(pin) return pin.kind .. ':' .. pin.value end

--- Gives `into` the pin of `from`, another spec of the same plugin, when `into` has none. Returns false when both
--- have one and they differ.
function M.adopt(into, from)
    local theirs = M.of(from)
    if not theirs then return true end
    local mine = M.of(into)
    if mine then return M.key(mine) == M.key(theirs) end
    for _, key in ipairs(KEYS) do
        if from[key] ~= nil then into[key] = from[key] end
    end
    return true
end

--- The refs `git ls-remote` listed, as ref -> commit. A peeled tag (`refs/tags/v1^{}`) gives its tag the commit
--- the tag points at, not the id of the tag object.
function M.refs(output)
    local found = {}
    for sha, ref in output:gmatch('(%x+)%s+(%S+)') do
        local tag = ref:match('^(.*)%^{}$')
        if tag then
            found[tag] = sha
        elseif found[ref] == nil then
            found[ref] = sha
        end
    end
    return found
end

--- The highest tag of `refs` inside the range of a `version` pin, as its name and commit. Prereleases and tags
--- that do not start like a version are not considered.
function M.newest(pin, refs)
    local best
    for ref, sha in pairs(refs) do
        local name = ref:match('^refs/tags/(v?%d.*)$')
        local version = name and vim.version.parse(name, { strict = false })
        if version and not version.prerelease and pin.range:has(version) then
            local newer = not best or vim.version.gt(version, best.version)
            if best and vim.version.eq(version, best.version) then newer = name < best.name end
            if newer then best = { name = name, sha = sha, version = version } end
        end
    end
    if best then return best.name, best.sha end
end

return M
