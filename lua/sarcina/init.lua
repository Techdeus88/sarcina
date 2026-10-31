--- sarcina/init.lua
-- Entry point for the Sarcina plugin manager

local M = {}

local ui = require("sarcina.ui")
local manifest = require("sarcina.manifest")
local resolver = require("sarcina.resolver")
local installer = require("sarcina.installer")

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

	-- 3️⃣ Queue every plugin's tasks and run them in the background. Lazy plugins register their
	-- triggers and load later; the rest clone, join the runtimepath and run their config.
	installer.install_all(resolved)
end

return M
