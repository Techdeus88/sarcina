-- sarcina/task_factory.lua
-- Generates a default ordered list of tasks for a plugin spec.
-- Users can provide custom fields (build, triggers, opts, config, main, etc.)
-- without explicitly writing a `tasks` list. This module translates those
-- shorthand fields into the normalized task structures that the task engine
-- understands.

local M = {}

-- A string runs as a Lua chunk; a function is kept as a closure.
local function lua_task(id, value, opts)
	local task = { id = id, type = "lua", opts = opts }
	if type(value) == "function" then
		task.fn = value
	elseif type(value) == "string" then
		task.script = value
	end
	return task
end

-- `config` wins; otherwise `main` is required and gets `setup(opts)` when opts exist.
local function load_task(spec)
	if spec.config then
		return lua_task("load", spec.config, spec.opts)
	end
	if spec.main then
		local main = spec.main
		return lua_task("load", function(_, opts)
			local mod = require(main)
			if opts ~= nil and type(mod) == "table" and type(mod.setup) == "function" then
				mod.setup(opts)
			end
		end, spec.opts)
	end
end

-- Task order: before, install, build, rtp, load_trigger, load, after.
function M.generate(spec)
	local tasks = {}

	local before = spec.init or spec.before
	if before then
		table.insert(tasks, lua_task("before", before))
	end

	if spec.repo then
		table.insert(tasks, { id = "install", type = "git_clone", repo = spec.repo, opt = spec.opt })
	end

	if spec.build then
		table.insert(tasks, lua_task("build", spec.build))
	end

	table.insert(tasks, { id = "rtp", type = "rtp", opt = spec.opt })

	local trigger = {}
	if spec.event then
		trigger.event = spec.event
	end
	if spec.ft then
		trigger.ft = spec.ft
	end
	if spec.cmd then
		trigger.cmd = spec.cmd
	end
	if spec.keys then
		trigger.keys = spec.keys
	end
	if next(trigger) ~= nil then
		table.insert(tasks, { id = "load_trigger", type = "trigger", triggers = trigger })
	end

	local load = load_task(spec)
	if load then
		table.insert(tasks, load)
	end

	if spec.after then
		table.insert(tasks, lua_task("after", spec.after))
	end

	return tasks
end

return M
