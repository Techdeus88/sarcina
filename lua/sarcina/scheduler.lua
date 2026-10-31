-- sarcina/scheduler.lua
-- Registers lazy‑load triggers for all installed plugins.
-- Called after `installer.install_all` (or anytime new plugins appear).

local M = {}

local ui = require("sarcina.ui")

-- Keep track of augroup IDs so we can clear them later if we need to reload.
M._augroups = {}

--- Helper: create a key‑map that emits an info event when pressed.
local function map_key(plugin, lhs, mode, desc, opts)
	local key_opts = vim.tbl_extend("force", { noremap = true, silent = true }, opts or {})
	if desc then
		key_opts.desc = desc
	end
	vim.api.nvim_set_keymap(
		mode,
		lhs,
		string.format(
			[[<Cmd>lua require('sarcina.ui').emit('info',
                'Key %s for plugin %s fired')<CR>]],
			lhs,
			plugin
		),
		key_opts
	)
end

--- Register triggers for a *single* plugin spec.
local function register_one(plugin, spec)
	local trig = spec.triggers or {}
	local aug_name = "SarcinaScheduler_" .. plugin
	local aug = vim.api.nvim_create_augroup(aug_name, { clear = true })
	M._augroups[plugin] = aug

	-- Event autocommands (e.g., BufRead, InsertEnter)
	if trig.event then
		vim.api.nvim_create_autocmd(trig.event, {
			group = aug,
			pattern = "*",
			callback = function()
				ui.emit("info", string.format("Event %s triggered for %s", trig.event, plugin))
				-- Here you could actually *load* the plugin if you want lazy loading
				-- beyond just emitting an info message.
			end,
		})
	end

	-- Filetype autocommands
	if trig.ft then
		vim.api.nvim_create_autocmd("FileType", {
			group = aug,
			pattern = trig.ft,
			callback = function()
				ui.emit("info", string.format("Filetype %s triggered for %s", trig.ft, plugin))
			end,
		})
	end

	-- User command
	if trig.cmd then
		vim.api.nvim_create_user_command(trig.cmd, function()
			ui.emit("info", string.format("Command %s triggered for %s", trig.cmd, plugin))
		end, { nargs = "*" })
	end

	-- Keys (array of strings or tables)
	if trig.keys then
		for _, map in ipairs(trig.keys) do
			local lhs, mode, desc, opts = nil, "n", nil, {}
			if type(map) == "string" then
				lhs = map
			elseif type(map) == "table" then
				lhs = map.lhs or map[1]
				mode = map.mode or map[2] or "n"
				desc = map.desc or map[3]
				opts = map.opts or {}
			end
			if lhs then
				map_key(plugin, lhs, mode, desc, opts)
			end
		end
	end
end

--- Public API ---------------------------------------------------------
--- `schedule_all(resolved)` registers triggers for every plugin in the
--- ordered list that `resolver.resolve` returned.
function M.schedule_all(resolved)
	if type(resolved) ~= "table" then
		ui.emit("error", "Scheduler received a non‑table resolved list")
		return
	end

	for _, entry in ipairs(resolved) do
		local name = entry.name
		local spec = entry.spec
		if spec.triggers then
			local ok, err = pcall(register_one, name, spec)
			if not ok then
				ui.emit("error", string.format("Failed to schedule triggers for %s: %s", name, err))
			else
				ui.emit("info", string.format("Scheduled lazy‑load triggers for %s", name))
			end
		end
	end
end

--- Optional: clear all scheduler augroups (useful for a full reload)
function M.clear_all()
	for _, aug in pairs(M._augroups) do
		vim.api.nvim_del_augroup_by_id(aug)
	end
	M._augroups = {}
	ui.emit("info", "All Sarcina scheduler augroups cleared")
end

return M
