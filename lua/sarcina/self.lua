-- sarcina/self.lua
-- Sarcina's own checkout. It is found from where this file is, so it works wherever Sarcina was installed: by the
-- bootstrap of your config (often inside the plugins directory), by another plugin manager, or as a working copy.
-- The checker looks at it before the plugins, the updater moves it like one, and `clean` and `delete` never take
-- it for a plugin of their own. It follows the `stable` branch, the latest release, unless setup() pins it.

local M = {}

--- The name Sarcina has in the Updates list and for `:Sarcina update`.
M.name = 'sarcina'

--- The directory to use instead of the one this file is in; false turns the self-check off. For tests.
M.root = nil

--- What Sarcina follows without a `pin`: the `stable` branch, which the release workflow moves to each release.
M.DEFAULT_PIN = { branch = 'stable' }

--- The `pin` option of setup(), as in a spec: `{ tag = 'v0.2.0' }`, `{ version = '0.*' }`, `{ branch = 'main' }`
--- or `{ commit = '…' }`. nil follows DEFAULT_PIN.
M.pin = nil

local PIN_KEYS = { 'commit', 'tag', 'version', 'branch' }

--- The directory Sarcina runs from, or nil when the self-check is off.
function M.dir()
    if M.root == false then return nil end
    if M.root then return M.root end
    local source = debug.getinfo(1, 'S').source:sub(2)
    return vim.fs.normalize(vim.fn.fnamemodify(source, ':p:h:h:h'))
end

--- Whether the job or entry `name` is Sarcina itself, which counts apart from your plugins: Sarcina has no row,
--- so a plugin of yours with the same name still counts as one.
function M.named(name) return name == M.name and require('sarcina.stats').plugin(name) == nil end

--- Whether `dir` is Sarcina's own directory, links resolved.
function M.is(dir)
    local own = M.dir()
    if not own then return false end
    local real = vim.uv.fs_realpath(dir)
    return real ~= nil and real == vim.uv.fs_realpath(own)
end

--- Sarcina as an entry of a resolved manifest, `{ name, timing, spec, dir }`, or nil when its directory is not a
--- git checkout, which nothing could check or update. Its spec carries `pin`, or DEFAULT_PIN.
function M.entry()
    local dir = M.dir()
    if not dir or not vim.uv.fs_stat(dir .. '/.git') then return nil end
    local spec = { name = M.name, repo = 'self', self = true }
    local pin = type(M.pin) == 'table' and M.pin or M.DEFAULT_PIN
    for _, key in ipairs(PIN_KEYS) do
        spec[key] = pin[key]
    end
    return { name = M.name, timing = 'now', dir = dir, spec = spec }
end

return M
