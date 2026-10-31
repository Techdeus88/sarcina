--- sarcina/init.lua
-- Entry point for the Sarcina plugin manager

local M = {}

local ui = require("sarcina.ui")
local manifest = require("sarcina.manifest")
local resolver = require("sarcina.resolver")
local installer = require("sarcina.installer")
local scheduler = require("sarcina.scheduler")

--- User‑facing entry point.
--- Call `require('sarcina').setup()` after adding Sarcina to your runtimepath.
--- Tasks run in the background; `require('sarcina.tasks').wait()` blocks until they finish.
function M.setup(opts)
	opts = opts or {}
	ui.init()

	-- 1️⃣ Load all plugin specs (auto‑discovers files under lua/plugins/ or custom paths)
	local specs = manifest.load(opts)

	-- 2️⃣ Resolve dependencies and order plugins
	local resolved = resolver.resolve(specs)

	-- 3️⃣ Queue every plugin's tasks (clone, rtp, config, ...) and run them in the background
	-- 4️⃣ Register lazy‑load triggers (event/ft/cmd/keys) once the queue has drained
	installer.install_all(resolved, function()
		scheduler.schedule_all(resolved)
	end)
end

return M
