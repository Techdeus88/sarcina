--- sarcina/init.lua
-- Entry point for the Sarcina plugin manager

local M = {}

local ui = require('sarcina.ui')
local manifest = require('sarcina.manifest')
local resolver = require('sarcina.resolver')
local load = require('sarcina.load')
local startup = require('sarcina.startup')
local stats = require('sarcina.stats')

--- Run `f` safely, now, after the UI is up, or when an event or filetype fires. See sarcina.load.
M.safely, M.now, M.later, M.now_if_args = load.safely, load.now, load.later, load.now_if_args

--- Numbers about the session: count, loaded, not_loaded, now, later, triggered and startup_ms.
M.stats = stats.get

--- User‑facing entry point.
--- Call `require('sarcina').setup()` after adding Sarcina to your runtimepath.
--- Installed `now` plugins load before it returns; the rest runs in the background once the UI is up,
--- and `require('sarcina.tasks').wait()` blocks until it is done.
function M.setup(opts)
    stats.begin()
    opts = opts or {}
    ui.init()

    -- 1️⃣ Load all plugin specs (auto‑discovers files under lua/plugins/ or custom paths)
    local specs = manifest.load(opts)

    -- 2️⃣ Resolve dependencies and order plugins
    local resolved = resolver.resolve(specs)
    stats.register(resolved)

    -- 3️⃣ Load the installed `now` plugins at once and queue the rest for after the UI is up. Installs go
    -- first, then builds, then the `later` plugins and the triggers of the lazy ones.
    startup.start(resolved)
end

return M
