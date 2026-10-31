local h = require("helpers")
local tasks = require("sarcina.tasks")
local executors = require("sarcina.executors")
local ui = require("sarcina.ui")

local tests = {}
local function test(name, fn)
	table.insert(tests, { name, fn })
end

executors.t_slow = function(_, done)
	vim.defer_fn(function()
		done(true)
	end, 150)
end

local function win_open()
	return ui._winid ~= nil and vim.api.nvim_win_is_valid(ui._winid)
end

local function lines()
	return vim.api.nvim_buf_get_lines(ui._bufnr, 0, -1, false)
end

local function title()
	local text = vim.api.nvim_win_get_config(ui._winid).title
	if type(text) == "table" then
		text = table.concat(vim.tbl_map(function(chunk)
			return type(chunk) == "table" and chunk[1] or chunk
		end, text))
	end
	return text
end

local function failing(name)
	return {
		name = name,
		tasks = {
			h.lua("x", function()
				error("no")
			end),
		},
	}
end

test("rows keep enqueue order and failures get their own glyph", function()
	local plugins = {}
	for i = 1, 6 do
		local fn = i == 3
				and function()
					error("boom")
				end
			or h.noop
		table.insert(plugins, { name = "plugin" .. i, tasks = { h.lua("load", fn) } })
	end
	h.run(plugins)
	ui.open()
	local got = lines()
	h.eq(#got, 6)
	for i = 1, 6 do
		h.ok(got[i]:find("plugin" .. i, 1, true), "row " .. i .. " is " .. got[i])
	end
	h.ok(vim.startswith(got[1], "✔"))
	h.ok(vim.startswith(got[3], "✘"))
	h.ok(got[3]:find("error: ", 1, true))
end)

test("the panel shows a job as running while it runs", function()
	ui.show_delay = 0
	tasks.enqueue("slow", { tasks = { { id = "a", type = "t_slow" } } })
	tasks.run_all()
	h.ok(vim.wait(100, win_open), "panel never opened")
	h.ok(vim.startswith(lines()[1], "▶"), lines()[1])
	h.ok(tasks.wait(2000))
	h.ok(vim.wait(200, function()
		return vim.startswith(lines()[1], "✔")
	end))
end)

test("the title counts finished jobs and failures", function()
	h.run({ failing("a"), { name = "b", tasks = { h.lua("y", h.noop), h.lua("z", h.noop) } } })
	ui.open()
	h.eq(title(), " Sarcina 3/3 · 1 failed ")
end)

test("a failure opens the panel on its own", function()
	h.run({ failing("a") })
	h.ok(vim.wait(200, win_open))
end)

test("a quick clean run never opens the panel", function()
	h.run({ { name = "p", tasks = { h.lua("a", h.noop) } } })
	vim.wait(400)
	h.eq(ui._winid, nil)
end)

test("closing the window dismisses the panel until the next run", function()
	h.run({ failing("p") })
	h.ok(vim.wait(200, win_open))
	vim.api.nvim_win_close(ui._winid, true)
	h.eq(ui._dismissed, true)
	h.run({ failing("p") })
	h.ok(vim.wait(200, win_open), "panel did not come back for the new run")
end)

test("q dismisses the panel", function()
	h.run({ failing("p") })
	h.ok(vim.wait(200, win_open))
	local map = vim.api.nvim_buf_call(ui._bufnr, function()
		return vim.fn.maparg("q", "n", false, true)
	end)
	h.eq(map.buffer, 1)
	map.callback()
	h.eq(win_open(), false)
	h.eq(ui._dismissed, true)
end)

test("a clean run closes the panel after close_delay", function()
	ui.show_delay = 0
	ui.close_delay = 50
	tasks.enqueue("slow", { tasks = { { id = "a", type = "t_slow" } } })
	tasks.run_all()
	h.ok(vim.wait(100, win_open))
	h.ok(tasks.wait(2000))
	h.ok(vim.wait(500, function()
		return not win_open()
	end))
end)

test("warn and warning both notify", function()
	ui.emit("warn", "a")
	ui.emit("warning", "b")
	h.eq(#h.notes, 2)
	h.eq(h.notes[1].level, vim.log.levels.WARN)
	h.eq(h.notes[2].level, vim.log.levels.WARN)
end)

test("the end-of-run summary reports failures at error level", function()
	h.run({ failing("p") })
	local last = h.notes[#h.notes]
	h.eq(last.msg, "[Sarcina] 0 done, 1 failed")
	h.eq(last.level, vim.log.levels.ERROR)
end)

return tests
