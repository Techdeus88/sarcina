-- sarcina/paths.lua
-- Filesystem locations shared by the task factory and the executors.

local M = {}

function M.pack_dir(opt)
	return vim.fn.stdpath("data") .. "/site/pack/sarcina/" .. (opt and "opt/" or "start/")
end

function M.install(name, opt)
	return M.pack_dir(opt) .. name
end

function M.staging(name)
	return string.format("%s/sarcina_staging/%s_%d", vim.fn.stdpath("cache"), name, vim.uv.hrtime())
end

return M
