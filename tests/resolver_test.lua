local h = require("helpers")
local resolver = require("sarcina.resolver")

local tests = {}
local function test(name, fn)
	table.insert(tests, { name, fn })
end

test("derives the plugin name from a bare repo", function()
	local resolved = resolver.resolve({ { repo = "nvim-lua/plenary.nvim" } })
	h.eq(h.names(resolved), { "plenary.nvim" })
end)

test("puts dependencies before the plugins that need them", function()
	local resolved = resolver.resolve({
		{ name = "app", repo = "x/app", deps = { "lib" } },
		{ name = "lib", repo = "x/lib", deps = { "base" } },
		{ name = "base", repo = "x/base" },
	})
	h.eq(h.names(resolved), { "base", "lib", "app" })
end)

test("keeps manifest order for independent plugins", function()
	local specs = {}
	for _, name in ipairs({ "e", "b", "d", "a", "c" }) do
		table.insert(specs, { name = name, repo = "x/" .. name })
	end
	h.eq(h.names(resolver.resolve(specs)), { "e", "b", "d", "a", "c" })
end)

test("rejects a dependency cycle", function()
	local resolved = resolver.resolve({
		{ name = "a", repo = "x/a", deps = { "b" } },
		{ name = "b", repo = "x/b", deps = { "a" } },
	})
	h.eq(resolved, {})
	h.ok(h.notified("Circular dependency"))
end)

test("rejects an unknown dependency", function()
	local resolved = resolver.resolve({ { name = "a", repo = "x/a", deps = { "ghost" } } })
	h.eq(resolved, {})
	h.ok(h.notified("unknown dependency ghost"))
end)

test("attaches generated tasks to each spec", function()
	local resolved = resolver.resolve({ { name = "a", repo = "x/a" } })
	h.eq(h.ids(resolved[1].spec.tasks), { "install", "rtp" })
end)

return tests
