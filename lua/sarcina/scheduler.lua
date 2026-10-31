-- sarcina/scheduler.lua
-- Lazy-load triggers. The `trigger` task hands its plugin to `register`, which installs stubs for
-- the plugin's event/ft/cmd/keys. The first stub to fire removes them all, runs the plugin's
-- deferred tasks (rtp, config, after) through the task runner, then replays what triggered it.

local M = {}

local tasks = require("sarcina.tasks")
local ui = require("sarcina.ui")

-- name -> { name, triggers, deferred, deps, state = waiting|loading|loaded|failed, ... }
M._plugins = {}

local function parse_key(map)
	if type(map) == "string" then
		return { lhs = map, mode = "n", opts = {} }
	end
	return {
		lhs = map.lhs or map[1],
		mode = map.mode or map[2] or "n",
		desc = map.desc or map[3],
		opts = map.opts or {},
	}
end

--- One-line summary of a triggers table, e.g. "BufRead, ft:lua, :Telescope, <leader>ff".
function M.describe(triggers)
	local parts = {}
	for _, event in ipairs(triggers.event or {}) do
		table.insert(parts, event)
	end
	for _, ft in ipairs(triggers.ft or {}) do
		table.insert(parts, "ft:" .. ft)
	end
	for _, cmd in ipairs(triggers.cmd or {}) do
		table.insert(parts, ":" .. cmd)
	end
	for _, map in ipairs(triggers.keys or {}) do
		table.insert(parts, parse_key(map).lhs)
	end
	return table.concat(parts, ", ")
end

local function try(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		ui.emit("error", string.format("%s failed: %s", label, err))
	end
end

-- Replay -----------------------------------------------------------------------------------

local function pattern_matches(pattern, match)
	return vim.fn.match(match or "", vim.fn.glob2regpat(pattern)) >= 0
end

local function autocmd_key(au)
	return au.id or table.concat({ tostring(au.group), au.pattern, tostring(au.command) }, "\0")
end

local function snapshot_autocmds(event)
	local seen = {}
	for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
		seen[autocmd_key(au)] = true
	end
	return seen
end

-- Only autocmds that appeared since `seen` run again, so other plugins' handlers never fire twice.
local function replay_autocmds(event, args, seen)
	for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
		local applies = au.buflocal and au.buffer == args.buf
			or not au.buflocal and pattern_matches(au.pattern, args.match)
		if applies and not seen[autocmd_key(au)] then
			if type(au.callback) == "function" then
				try("Replaying " .. event, au.callback, args)
			elseif au.command and au.command ~= "" then
				try("Replaying " .. event, vim.api.nvim_buf_call, args.buf, function()
					vim.cmd(au.command)
				end)
			end
		end
	end
end

-- Each `prepare` runs once the stubs are gone and returns the function that replays the trigger.
local function prepare_event(event, args)
	return function()
		local seen = snapshot_autocmds(event)
		return function()
			replay_autocmds(event, args, seen)
		end
	end
end

local function prepare_command(cmd, opts)
	return function()
		return function()
			local range
			if opts.range == 2 then
				range = { opts.line1, opts.line2 }
			elseif opts.range == 1 then
				range = { opts.line1 }
			end
			try("Running :" .. cmd, vim.cmd, {
				cmd = cmd,
				args = opts.fargs,
				bang = opts.bang,
				range = range,
				mods = opts.smods,
			})
		end
	end
end

local function prepare_keys(lhs)
	return function()
		return function()
			vim.api.nvim_feedkeys(vim.keycode(lhs), "mit", false)
		end
	end
end

-- Stubs ------------------------------------------------------------------------------------

local function arm(plugin)
	local name, triggers = plugin.name, plugin.triggers
	plugin.augroup = vim.api.nvim_create_augroup("SarcinaScheduler_" .. name, { clear = true })

	for _, spec in ipairs(triggers.event or {}) do
		local event, pattern = spec:match("^(%S+)%s+(.+)$")
		event = event or spec
		vim.api.nvim_create_autocmd(event, {
			group = plugin.augroup,
			pattern = pattern or "*",
			callback = function(args)
				M.load(name, prepare_event(event, args))
			end,
		})
	end

	if triggers.ft then
		vim.api.nvim_create_autocmd("FileType", {
			group = plugin.augroup,
			pattern = triggers.ft,
			callback = function(args)
				M.load(name, prepare_event("FileType", args))
			end,
		})
	end

	for _, cmd in ipairs(triggers.cmd or {}) do
		vim.api.nvim_create_user_command(cmd, function(opts)
			M.load(name, prepare_command(cmd, opts))
		end, { nargs = "*", bang = true, range = true })
		table.insert(plugin.commands, cmd)
	end

	for _, map in ipairs(triggers.keys or {}) do
		local key = parse_key(map)
		if key.lhs then
			local opts = vim.tbl_extend("force", { silent = true, desc = key.desc }, key.opts)
			vim.keymap.set(key.mode, key.lhs, function()
				M.load(name, prepare_keys(key.lhs))
			end, opts)
			table.insert(plugin.keymaps, { mode = key.mode, lhs = key.lhs })
		end
	end
end

local function disarm(plugin)
	pcall(vim.api.nvim_del_augroup_by_id, plugin.augroup)
	for _, cmd in ipairs(plugin.commands) do
		pcall(vim.api.nvim_del_user_command, cmd)
	end
	for _, key in ipairs(plugin.keymaps) do
		pcall(vim.keymap.del, key.mode, key.lhs)
	end
	plugin.commands, plugin.keymaps = {}, {}
end

-- Public API -------------------------------------------------------------------------------

--- Install stubs for `name`. `entry` is a trigger task: { triggers, deferred, deps }.
function M.register(name, entry)
	local previous = M._plugins[name]
	if previous then
		disarm(previous)
	end
	local plugin = {
		name = name,
		triggers = entry.triggers,
		deferred = entry.deferred or {},
		deps = entry.deps or {},
		state = "waiting",
		commands = {},
		keymaps = {},
	}
	M._plugins[name] = plugin
	arm(plugin)
end

function M.state(name)
	local plugin = M._plugins[name]
	return plugin and plugin.state
end

-- Claims `name` and every still-waiting dependency, dependencies first.
local function claim(name, claimed)
	local plugin = M._plugins[name]
	if not plugin or plugin.state ~= "waiting" then
		return
	end
	plugin.state = "loading"
	disarm(plugin)
	for _, dep in ipairs(plugin.deps) do
		claim(dep, claimed)
	end
	table.insert(claimed, plugin)
end

--- Load `name` now. `prepare`, when given, returns the function to run once the load succeeds.
function M.load(name, prepare)
	local claimed = {}
	claim(name, claimed)
	if #claimed == 0 then
		return
	end
	local replay = prepare and prepare()
	for _, plugin in ipairs(claimed) do
		tasks.enqueue(plugin.name, { deps = plugin.deps, tasks = plugin.deferred })
	end
	tasks.run_all(function()
		for _, plugin in ipairs(claimed) do
			plugin.state = tasks.plugin_failed(plugin.name) and "failed" or "loaded"
		end
		if replay and M._plugins[name].state == "loaded" then
			replay()
		end
	end, { quiet = true })
end

--- Remove every stub and forget every registered plugin.
function M.clear_all()
	for _, plugin in pairs(M._plugins) do
		disarm(plugin)
	end
	M._plugins = {}
end

return M
