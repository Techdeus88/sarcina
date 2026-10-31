-- Run from the repo root:
--   nvim --headless -u NONE -c "luafile tests/run.lua"
-- Set SARCINA_TEST_FILTER to a substring to run matching tests only.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local h = require("helpers")
h.setup_env()

local filter = os.getenv("SARCINA_TEST_FILTER")
local passed, failures = 0, {}

local function out(text)
	io.stdout:write(text, "\n")
	io.stdout:flush()
end

for _, file in ipairs(vim.fn.glob(root .. "/tests/*_test.lua", false, true)) do
	local label = vim.fn.fnamemodify(file, ":t:r")
	for _, case in ipairs(dofile(file)) do
		local name, fn = case[1], case[2]
		if not filter or (label .. " " .. name):find(filter, 1, true) then
			h.reset()
			local ok, err = xpcall(fn, debug.traceback)
			if ok then
				passed = passed + 1
				out("ok   " .. label .. " > " .. name)
			else
				table.insert(failures, { label .. " > " .. name, err })
				out("FAIL " .. label .. " > " .. name)
			end
		end
	end
end

out(string.format("\n%d passed, %d failed", passed, #failures))
for _, failure in ipairs(failures) do
	out("\n--- " .. failure[1] .. "\n" .. failure[2])
end

if #failures > 0 then
	vim.cmd("cquit 1")
else
	vim.cmd("qall!")
end
