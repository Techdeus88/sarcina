local h = require("helpers")
local factory = require("sarcina.task_factory")

local tests = {}
local function test(name, fn)
	table.insert(tests, { name, fn })
end

local function find(tasks, id)
	for _, task in ipairs(tasks) do
		if task.id == id then
			return task
		end
	end
end

test("a bare repo gets install and rtp only", function()
	h.eq(h.ids(factory.generate({ repo = "x/y" })), { "install", "rtp" })
end)

test("orders every phase", function()
	local tasks = factory.generate({
		repo = "x/y",
		init = "a",
		build = "b",
		event = "BufRead",
		config = "c",
		after = "d",
	})
	h.eq(h.ids(tasks), { "before", "install", "build", "rtp", "load_trigger", "load", "after" })
end)

test("keeps function values as closures", function()
	local called = false
	local tasks = factory.generate({
		repo = "x/y",
		build = function()
			called = true
		end,
	})
	find(tasks, "build").fn()
	h.ok(called)
end)

test("keeps string values as scripts", function()
	h.eq(find(factory.generate({ repo = "x/y", build = "return 1" }), "build").script, "return 1")
end)

test("hands opts to config as the second argument", function()
	local got
	local tasks = factory.generate({
		repo = "x/y",
		opts = { a = 1 },
		config = function(_, opts)
			got = opts
		end,
	})
	local load = find(tasks, "load")
	load.fn(nil, load.opts)
	h.eq(got, { a = 1 })
end)

test("main with opts calls setup(opts)", function()
	local got
	package.preload["sarcina_test_mod"] = function()
		return {
			setup = function(opts)
				got = opts
			end,
		}
	end
	local load = find(factory.generate({ repo = "x/y", main = "sarcina_test_mod", opts = { b = 2 } }), "load")
	load.fn(nil, load.opts)
	package.preload["sarcina_test_mod"], package.loaded["sarcina_test_mod"] = nil, nil
	h.eq(got, { b = 2 })
end)

test("carries opt onto install and rtp", function()
	local tasks = factory.generate({ repo = "x/y", opt = true })
	h.eq(find(tasks, "install").opt, true)
	h.eq(find(tasks, "rtp").opt, true)
end)

return tests
